// SPDX-License-Identifier: GPL-2.0-only
#ifndef ReYogaControlRequest_hpp
#define ReYogaControlRequest_hpp

#include "common.h"
#include "ControlValidation.hpp"
#include <IOKit/IOReturn.h>

namespace ReYogaControl {
// Borrowed for the synchronous gated request; the result retains its values.
struct ControlEnvelope {
    OSString *property{nullptr};
    OSString *requestID{nullptr};
    OSObject *value{nullptr};
};

inline bool parseControlEnvelope(const OSDictionary *request, ControlEnvelope &envelope) {
    envelope = {};
    if (!request)
        return false;
    auto property = ReYogaProperty::get<OSString>(request, "Property");
    auto requestID = ReYogaProperty::get<OSString>(request, "RequestID");
    auto value = request->getObject("Value");
    if (!property || !requestID || !value ||
        !validControlEnvelopeLengths(property->getLength(), requestID->getLength()))
        return false;
    envelope.property = property;
    envelope.requestID = requestID;
    envelope.value = value;
    return true;
}

// Returns an owned result. Allocation failure cannot mask a failed readback.
inline OSDictionary *makeControlResult(const ControlEnvelope &envelope, OSObject *actual,
                                       IOReturn commandStatus, IOReturn &status) {
    status = commandStatus;
    if (status == kIOReturnSuccess && (!actual || !actual->isEqualTo(envelope.value)))
        status = kIOReturnIOError;
    auto result = OSDictionary::withCapacity(12);
    if (!result)
        return nullptr;
    bool complete = result->setObject("RequestID", envelope.requestID) &&
                    result->setObject("Property", envelope.property) &&
                    result->setObject("Requested", envelope.value);
    if (actual)
        complete = result->setObject("Actual", actual) && complete;
    complete = ReYogaProperty::setNumber(result, "Status", status, 32) && complete;
    complete = ReYogaProperty::setNumber(result, "CommandStatus", commandStatus, 32) && complete;
    complete = ReYogaProperty::setBoolean(result, "ReadbackPending",
                                          commandStatus == kIOReturnSuccess && status != kIOReturnSuccess) &&
               complete;
    if (!complete) {
        result->release();
        return nullptr;
    }
    return result;
}
} // namespace ReYogaControl

#endif
