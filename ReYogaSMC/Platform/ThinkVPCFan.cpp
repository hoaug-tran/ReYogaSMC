// SPDX-License-Identifier: GPL-2.0-only
// Original work: Copyright (c) 2020 Zhen.

#include "ThinkVPC.hpp"
#include <pexpert/pexpert.h>

void ThinkVPC::updateFans() {
    const unsigned count = getProperty("Dual fan") == kOSBooleanTrue ? 2 : 1;
    auto telemetry = OSDictionary::withCapacity(3);
    for (unsigned fan = 0; fan < count; ++fan) {
        UInt32 rpm = 0;
        UInt8 control = 0xff;
        const char *property = fan == 0 ? "Fan1RPM" : "Fan2RPM";
        const IOReturn status = readThinkFanRPM(fan, rpm, &control);
        const bool validRPM = status == kIOReturnSuccess;
        if (validRPM)
            setProperty(property, rpm, 32);
        else if (status != kIOReturnUnderrun)
            removeProperty(property);
        auto reading = OSDictionary::withCapacity(2);
        if (reading) {
            if (validRPM)
                ReYogaProperty::setNumber(reading, "RPM", rpm, 32);
            else if (status == kIOReturnUnderrun && getProperty(property)) {
                if (auto *lastRPM = OSDynamicCast(OSNumber, getProperty(property)))
                    ReYogaProperty::setNumber(reading, "RPM", lastRPM->unsigned32BitValue(), 32);
            }
            if (control != 0xff)
                ReYogaProperty::setNumber(reading, "Control", control, 8);
            if (telemetry)
                telemetry->setObject(fan == 0 ? "Fan1" : "Fan2", reading);
            reading->release();
        }
    }
    if (telemetry) {
        UInt64 uptime, ns;
        clock_get_uptime(&uptime);
        absolutetime_to_nanoseconds(uptime, &ns);
        ReYogaProperty::setNumber(telemetry, "SensorSampleTimeMS", ns / 1000000, 64);
        setProperty("ThinkFanTelemetry", telemetry);
        telemetry->release();
    } else {
        removeProperty("ThinkFanTelemetry");
    }
}

bool ThinkVPC::updateFanControl(UInt32 status, bool logChanges) {
    if (evaluateIntegerParam(getThermalControl, &thermalstate, status) != kIOReturnSuccess) {
        AlwaysLog(updateFailure, __func__);
        return false;
    }

    if (logChanges) {
        DebugLog(updateSuccess, __func__, thermalstate);
    }
    setProperty(fanControlPrompt, thermalstate, 32);
    return true;
}

bool ThinkVPC::setFanControl(int level) {
    UInt32 result;
    if (evaluateIntegerParam(setThermalControl, &result, (level ? BIT(18) : 0)) != kIOReturnSuccess) {
        AlwaysLog(toggleFailure, fanControlPrompt);
        return false;
    }
    if (!result) {
        AlwaysLog(toggleFailure, "FanControl0");
        return false;
    }

    DebugLog(toggleSuccess, fanControlPrompt, (level ? BIT(18) : 0), (level ? "7" : "auto"));
    setProperty(fanControlPrompt, level, 32);
    return true;
}

void ThinkVPC::initPlatformControls() {
    thinkFanWatchdog = IOTimerEventSource::timerEventSource(this,
                                                            OSMemberFunctionCast(IOTimerEventSource::Action, this, &ThinkVPC::expireThinkFanCurve));
    if (thinkFanWatchdog && workLoop->addEventSource(thinkFanWatchdog) == kIOReturnSuccess) {
        thinkFanWatchdog->enable();
        setProperty("ThinkFanCurveVersion", 1, 32);
    } else {
        OSSafeReleaseNULL(thinkFanWatchdog);
    }
}

void ThinkVPC::exitPlatformControls() {
    if (thinkFanWatchdog) {
        thinkFanWatchdog->cancelTimeout();
        thinkFanWatchdog->disable();
        workLoop->removeEventSource(thinkFanWatchdog);
        OSSafeReleaseNULL(thinkFanWatchdog);
    }
}

static UInt64 thinkFanTimeMS() {
    UInt64 absolute = 0, nanoseconds = 0;
    clock_get_uptime(&absolute);
    absolutetime_to_nanoseconds(absolute, &nanoseconds);
    return nanoseconds / 1000000;
}

IOReturn ThinkVPC::accessPlatformFanCurve(UInt32 fan, UInt32 requested, UInt8 output[3]) {
    if (!output || fan > 1 || !((requested >= 1 && requested <= 7) || requested == 0x47))
        return kIOReturnBadArgument;
    if (!thinkFanWatchdog || getProperty("SafeMode") == kOSBooleanTrue)
        return kIOReturnUnsupported;
    if (fan && getProperty("Dual fan") != kOSBooleanTrue)
        return kIOReturnUnsupported;
    if (!commandGate || isInactive())
        return kIOReturnNotReady;
    struct Request {
        UInt32 fan, target;
        UInt8 *output;
    } request{fan, requested, output};
    return commandGate->runAction([](OSObject *owner, void *context, void *, void *, void *) -> IOReturn {
        auto self = static_cast<ThinkVPC *>(owner);
        auto request = static_cast<Request *>(context);
        if (self->stopping || self->isInactive())
            return kIOReturnNotAttached;
        // Arm before the write: failed transport may still have changed the EC.
        const bool running = self->thinkFanLease.active();
        self->thinkFanLease.renew(request->fan, thinkFanTimeMS());
        if (!running)
            self->thinkFanWatchdog->setTimeoutMS(1000);
        return self->accessThinkFanGated(request->fan, request->target, request->output);
    },
                                  &request);
}

void ThinkVPC::expireThinkFanCurve(OSObject *, IOTimerEventSource *) {
    if (!commandGate)
        return;
    commandGate->runAction([](OSObject *owner, void *, void *, void *, void *) -> IOReturn {
        auto self = static_cast<ThinkVPC *>(owner);
        if (self->stopping || !self->thinkFanWatchdog)
            return kIOReturnNotAttached;
        for (unsigned fan = 0; fan < 2; ++fan) {
            if (!self->thinkFanLease.expired(fan, thinkFanTimeMS()))
                continue;
            UInt8 output[3]{};
            if (self->accessThinkFanGated(fan, 0x84, output) == kIOReturnSuccess) {
                self->thinkFanLease.cancel(fan);
                self->setProperty("ThinkFanCurveStatus", "Watchdog confirmed BIOS Auto");
            } else {
                self->setProperty("ThinkFanStatus", "Curve watchdog: automatic fan restoration pending");
            }
        }
        if (self->thinkFanLease.active())
            self->thinkFanWatchdog->setTimeoutMS(1000);
        return kIOReturnSuccess;
    });
}

IOReturn ThinkVPC::accessPlatformFan(UInt32 fan, UInt32 requested, UInt8 output[3]) {
    if (!output || fan > 1 || (requested != ReYogaControl::kThinkFanQueryRPM && !ReYogaControl::validThinkFanLevel(requested)))
        return kIOReturnBadArgument;
    if (getProperty("SafeMode") == kOSBooleanTrue)
        return kIOReturnUnsupported;
    int bootArgument = 0;
    if (requested == 0 && !PE_parse_boot_argn("-reyfanstop", &bootArgument, sizeof(bootArgument)))
        return kIOReturnNotPermitted;
    if (!commandGate || isInactive())
        return kIOReturnNotReady;
    struct Request {
        UInt32 fan;
        UInt32 target;
        UInt8 *output;
    } request{fan, requested, output};
    return commandGate->runAction([](OSObject *owner, void *context, void *, void *, void *) -> IOReturn {
        auto self = static_cast<ThinkVPC *>(owner);
        auto request = static_cast<Request *>(context);
        if (self->stopping || self->isInactive())
            return kIOReturnNotAttached;
        const IOReturn status = self->accessThinkFanGated(request->fan, request->target, request->output);
        if (status == kIOReturnSuccess && request->target != ReYogaControl::kThinkFanQueryRPM)
            self->thinkFanLease.cancel(request->fan);
        return status;
    },
                                  &request);
}

IOReturn ThinkVPC::accessThinkFanGated(UInt32 fan, UInt32 requested, UInt8 output[3]) {
    // Only a reviewed service configuration may declare the EC selector layout.
    const bool hasSelector = getProperty("Dual fan") == kOSBooleanTrue;
    if (fan && !hasSelector)
        return kIOReturnUnsupported;
    IOReturn transport = kIOReturnSuccess;
    unsigned failedOffset = 0;
    const char *failedOperation = "readback";
    const auto result = ReYogaControl::transactThinkFan(fan, requested, output, hasSelector, thinkFans, [&](unsigned offset, UInt8 &value) {
            const IOReturn status = method_re1b(offset, &value, false);
            if (status != kIOReturnSuccess) {
                transport = status;
                failedOffset = offset;
                failedOperation = "read";
            }
            return status == kIOReturnSuccess; }, [&](unsigned offset, UInt8 value) {
            const IOReturn status = method_we1b(offset, value, false);
            if (status != kIOReturnSuccess) {
                transport = status;
                failedOffset = offset;
                failedOperation = "write";
            }
            return status == kIOReturnSuccess; });
    setProperty("ThinkFanAccessFailed", thinkFans.selectorRestorePending);
    IOReturn status = kIOReturnSuccess;
    switch (result) {
    case ReYogaControl::ThinkFanResult::ok:
        removeProperty("ThinkFanStatus");
        break;
    case ReYogaControl::ThinkFanResult::invalid:
        status = kIOReturnBadArgument;
        break;
    case ReYogaControl::ThinkFanResult::restoreFailed:
        setProperty("ThinkFanStatus", "Fan selector restoration pending; Auto recovery will retry with readback");
        status = kIOReturnIOError;
        break;
    default:
        status = transport != kIOReturnSuccess ? transport : kIOReturnIOError;
        break;
    }
    const bool poll = requested == ReYogaControl::kThinkFanQueryRPM;
    const bool changed = poll && thinkFans.pollStatusChanged(fan, static_cast<unsigned>(status));
    if (status != kIOReturnSuccess && (!poll || changed))
        AlwaysLog("ThinkFan %u target 0x%x failed 0x%x (transport 0x%x, %s @ 0x%02x, result %u)",
                  fan, requested, status, transport, failedOperation, failedOffset, static_cast<unsigned>(result));
    else if (changed)
        AlwaysLog("ThinkFan %u polling recovered", fan);
    return status;
}

IOReturn ThinkVPC::readPlatformFanRPM(UInt32 fan, UInt32 &rpm, UInt8 *control) {
    if (control)
        *control = 0xff;
    UInt8 sample[3]{};
    const IOReturn status = accessThinkFan(fan, ReYogaControl::kThinkFanQueryRPM, sample);
    if (status == kIOReturnSuccess) {
        if (control)
            *control = sample[2];
        rpm = ReYogaControl::thinkFanRPM(sample[0], sample[1]);
        return rpm != 0xffff ? kIOReturnSuccess : kIOReturnUnderrun;
    }
    if (fan != 0 || !commandGate)
        return status;
    return commandGate->runAction([](OSObject *owner, void *context, void *, void *, void *) -> IOReturn {
        auto self = static_cast<ThinkVPC *>(owner);
        if (self->stopping || self->isInactive() || self->getProperty("SafeMode") == kOSBooleanTrue ||
            self->thinkFans.selectorRestorePending)
            return kIOReturnNotReady;
        if (!self->ec || self->ec->validateObject("HSPD") != kIOReturnSuccess)
            return kIOReturnUnsupported;
        UInt32 raw = 0;
        const IOReturn result = self->ec->evaluateInteger("HSPD", &raw);
        if (result != kIOReturnSuccess)
            return result;
        if (raw >= 0xffff)
            return kIOReturnUnderrun;
        *static_cast<UInt32 *>(context) = raw;
        return kIOReturnSuccess;
    },
                                  &rpm);
}

void ThinkVPC::restorePlatformFans() {
    if (!commandGate || getProperty("SafeMode") == kOSBooleanTrue)
        return;
    commandGate->runAction([](OSObject *owner, void *, void *, void *, void *) -> IOReturn {
        auto self = static_cast<ThinkVPC *>(owner);
        if (!ReYogaControl::restoreThinkFanSelector(self->thinkFans, [&](unsigned offset, UInt8 &value) { return self->method_re1b(offset, &value) == kIOReturnSuccess; }, [&](unsigned offset, UInt8 value) { return self->method_we1b(offset, value) == kIOReturnSuccess; })) {
            self->setProperty("ThinkFanAccessFailed", true);
            self->setProperty("ThinkFanStatus", "Fan selector recovery failed; automatic restoration remains pending");
            return kIOReturnIOError;
        }
        self->setProperty("ThinkFanAccessFailed", false);
        IOReturn status = kIOReturnSuccess;
        for (unsigned fan = 0; fan < 2; ++fan) {
            if (!(self->thinkFans.modifiedMask & (1U << fan)))
                continue;
            UInt8 output[3]{};
            // Cleanup also runs during stop(), after normal client access ends.
            if (self->accessThinkFanGated(fan, 0x84, output) != kIOReturnSuccess) {
                status = kIOReturnIOError;
            } else {
                self->thinkFanLease.cancel(fan);
            }
        }
        if (status != kIOReturnSuccess)
            self->setProperty("ThinkFanStatus", "Automatic fan restoration failed; inspect firmware and restart");
        return status;
    });
}
