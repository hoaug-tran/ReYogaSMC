// SPDX-License-Identifier: GPL-2.0-only
// Original work: Copyright (c) 2020 Zhen.

#include "IdeaVPC.hpp"
#include "../WMI/IdeaWMI.hpp"
#include <libkern/crypto/sha2.h>
#include <IOKit/IODeviceTreeSupport.h>

bool IdeaVPC::initEC() {
    UInt32 state, attempts = 0;

    // _REG will write Arg1 to ECAV (or OKEC on old machines) to connect / disconnect the region
    if (ec->validateObject(getECStatus) == kIOReturnSuccess) {
        do {
            if (ec->evaluateInteger(getECStatus, &state) == kIOReturnSuccess && state != 0) {
                if (attempts != 0)
                    setProperty("EC Access Retries", attempts, 8);
                return true;
            }
            IOSleep(100);
        } while (++attempts < 5);
        AlwaysLog(updateFailure, getECStatus);
    }

    if (ec->validateObject(getECStatusLegacy) == kIOReturnSuccess) {
        do {
            if (ec->evaluateInteger(getECStatusLegacy, &state) == kIOReturnSuccess && state != 0) {
                if (attempts != 0)
                    setProperty("EC Access Retries", attempts, 8);
                return true;
            }
            IOSleep(100);
        } while (++attempts < 5);
        AlwaysLog(updateFailure, getECStatusLegacy);
    }

    // fallback to battery mode since some laptop don't have available keyboard mode
    do {
        if (vpc->evaluateInteger(getBatteryMode, &state) == kIOReturnSuccess ||
            vpc->evaluateInteger(getKeyboardMode, &state) == kIOReturnSuccess) {
            setProperty("EC Access Retries", attempts, 8);
            return true;
        }
        IOSleep(100);
    } while (++attempts < 10);
    AlwaysLog(initFailure, getBatteryMode);
    return false;
}

void IdeaVPC::updateKeyboardCapability() {
    UInt32 kbdState;
    IOReturn ret;

    ret = vpc->evaluateInteger(getKeyboardMode, &kbdState);
    if (ret != kIOReturnSuccess) {
        AlwaysLog(toggleError, keyboardPrompt, ret);
        return;
    }

    backlightCap = BIT(HA_BACKLIGHT_CAP) & kbdState;
    if (!backlightCap)
        setProperty(backlightPrompt, "unsupported");
    else
        setProperty(autoBacklightPrompt, automaticBacklightMode, 8);

    FnlockCap = BIT(HA_FNLOCK_CAP) & kbdState;
    if (!FnlockCap)
        setProperty(FnKeyPrompt, "unsupported");

    if (BIT(HA_PRIMEKEY_BIT) & kbdState)
        setProperty("PrimeKeyType", "HotKey");
    else
        setProperty("PrimeKeyType", "FnKey");

    alwaysOnUSBCap = BIT(HA_AOUSB_CAP) & kbdState;
    if (!alwaysOnUSBCap)
        setProperty(alwaysOnUSBPrompt, "unsupported");
}

void IdeaVPC::updateBatteryCapability() {
    UInt32 batState;
    IOReturn ret;

    ret = vpc->evaluateInteger(getBatteryMode, &batState);
    if (ret != kIOReturnSuccess) {
        AlwaysLog(toggleError, batteryPrompt, ret);
        return;
    }

    rapidChargeCap = BIT(BM_RAPIDCHARGE_CAP) & batState;
    if (!rapidChargeCap)
        setProperty(rapidChargePrompt, "unsupported");

    OSDictionary *bat0 = OSDictionary::withCapacity(5);
    OSDictionary *bat1 = OSDictionary::withCapacity(5);
    if (!bat0 || !bat1) {
        OSSafeReleaseNULL(bat0);
        OSSafeReleaseNULL(bat1);
        return;
    }
    if (BIT(BM0_BATTERYBAD_BIT) & batState) {
        bat0->setObject("Critical", kOSBooleanTrue);
        setProperty("Battery", "Critical");
        AlwaysLog("Battery 0 critical!");
        conservationModeLock = true;
    }

    if (BIT(BM1_BATTERYBAD_BIT) & batState) {
        bat1->setObject("Critical", kOSBooleanTrue);
        setProperty("Battery", "Critical");
        AlwaysLog("Battery 1 critical!");
        conservationModeLock = true;
    }

    if (updateBatteryID(bat0, bat1) && updateBatteryInfo(bat0, bat1)) {
        if (bat0->getCount())
            setProperty("Battery 0", bat0);
        if (bat1->getCount())
            setProperty("Battery 1", bat1);
    }
    bat0->release();
    bat1->release();
}

void IdeaVPC::initNativeProfile() {
    nativeProfile = nullptr;
    removeProperty("HardwareProfile");
    removeProperty("HardwareProfileName");
    setProperty("NativeTelemetryProfile", false);
    setProperty("ProfileMatchState", "unmatched");
    setProperty("ProfileMatchStage", "start");
    setProperty("ProfileMatchReason", bridgeDisabled ? "ACPI profile discovery disabled by -reynobridge" : "No reviewed DSDT fingerprint matched; WMI remains available");
    setProperty("NativeTelemetryReason", bridgeDisabled ? "ACPI profile discovery disabled by -reynobridge" : "No reviewed DSDT fingerprint matched; WMI remains available");
    if (bridgeDisabled || !ec) {
        setProperty("ProfileMatchStage", bridgeDisabled ? "disabled_by_boot_argument" : "ec_unavailable");
        AlwaysLog("Profile match skipped: %s", bridgeDisabled ? "disabled by -reynobridge" : "EC unavailable");
        return;
    }
    const OSData *table = vpc->getACPITableData("DSDT", 0);
    if (!table || table->getLength() < 36 || table->getLength() > 1024 * 1024) {
        setProperty("ProfileMatchStage", "dsdt_unavailable");
        setProperty("ProfileMatchReason", "DSDT unavailable or outside the validated size range");
        AlwaysLog("Profile match failed: DSDT unavailable or invalid size (%u)", table ? table->getLength() : 0);
        return;
    }
    const auto bytes = static_cast<const UInt8 *>(table->getBytesNoCopy());
    const UInt32 length = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24;
    if (memcmp(bytes, "DSDT", 4) || length != table->getLength()) {
        setProperty("ProfileMatchStage", "dsdt_header_invalid");
        setProperty("ProfileMatchReason", "DSDT header or length is invalid");
        AlwaysLog("Profile match failed: DSDT header/length invalid (declared=%u actual=%u)", length, table->getLength());
        return;
    }
    UInt8 checksum = 0;
    for (UInt32 i = 0; i < length; ++i)
        checksum += bytes[i];
    setProperty("FirmwareDSDTLength", length, 32);
    setProperty("FirmwareDSDTChecksum", checksum, 32);
    if (checksum) {
        setProperty("ProfileMatchStage", "dsdt_checksum_invalid");
        setProperty("ProfileMatchReason", "DSDT checksum is invalid");
        AlwaysLog("Profile match failed: DSDT checksum invalid (0x%02x)", checksum);
        return;
    }

    SHA256_CTX context;
    UInt8 digest[SHA256_DIGEST_LENGTH];
    SHA256_Init(&context);
    SHA256_Update(&context, bytes, length);
    SHA256_Final(digest, &context);
    char hex[SHA256_DIGEST_STRING_LENGTH] = {};
    for (unsigned i = 0; i < sizeof(digest); ++i)
        snprintf(hex + i * 2, sizeof(hex) - i * 2, "%02x", digest[i]);
    setProperty("FirmwareDSDTSHA256", hex);

    char oemTableID[9] = {};
    memcpy(oemTableID, bytes + 16, 8);
    for (int i = 7; i >= 0 && (oemTableID[i] == ' ' || oemTableID[i] == 0); --i)
        oemTableID[i] = 0;
    setProperty("FirmwareDSDTOEMTableID", oemTableID);
    setProperty("ProfileMatchStage", "identity_collected");
    AlwaysLog("Profile match evidence: DSDT length=%u checksum=0x%02x sha256=%s oem_table_id=%s", length, checksum, hex, oemTableID);

    ReYogaFirmware::Identity identity;
    auto readIdentity = [&](IORegistryEntry *entry) {
        if (!entry)
            return;
        const char *productKeys[] = {"OEMProduct", "OEMBoard", "product-name", "board-product", "machine-type"};
        const char *biosKeys[] = {"OEMBIOS", "OEMBIOSVersion", "bios-version"};
        auto read = [&](const char *key, bool bios) {
            auto object = entry->getProperty(key);
            if (auto text = OSDynamicCast(OSString, object))
                identity.add(text->getCStringNoCopy(), text->getLength(), bios);
            else if (auto data = OSDynamicCast(OSData, object))
                identity.add(static_cast<const char *>(data->getBytesNoCopy()), data->getLength(), bios);
        };
        for (const char *key : productKeys)
            read(key, false);
        for (const char *key : biosKeys)
            read(key, true);
    };
    const char *paths[] = {"/", "/efi/platform"};
    for (const char *path : paths) {
        auto entry = IORegistryEntry::fromPath(path, gIODTPlane);
        readIdentity(entry);
        OSSafeReleaseNULL(entry);
    }
    auto iterator = IORegistryIterator::iterateOver(gIOServicePlane, kIORegistryIterateRecursively);
    if (iterator) {
        while (auto entry = iterator->getNextObject()) {
            if (entry->metaCast("IOPlatformExpertDevice"))
                readIdentity(entry);
            if (entry->metaCast("IOPCIDevice")) {
                auto number = [&](const char *key) -> UInt32 {
                    auto object = entry->getProperty(key);
                    if (auto value = OSDynamicCast(OSNumber, object))
                        return value->unsigned32BitValue();
                    if (auto data = OSDynamicCast(OSData, object)) {
                        if (data->getLength() == 4) {
                            const auto raw = static_cast<const UInt8 *>(data->getBytesNoCopy());
                            return UInt32(raw[0]) | UInt32(raw[1]) << 8 | UInt32(raw[2]) << 16 | UInt32(raw[3]) << 24;
                        }
                    }
                    return 0;
                };
                identity.addPCI(number("subsystem-vendor-id"), number("subsystem-id"));
            }
            if (entry->metaCast("AppleSMBIOS")) {
                if (auto data = OSDynamicCast(OSData, entry->getProperty("SMBIOS")))
                    ReYogaFirmware::readSMBIOS(static_cast<const UInt8 *>(data->getBytesNoCopy()), data->getLength(), identity);
            }
        }
        iterator->release();
    }
    // Some bootloaders preserve OEM identity as EFI option properties. Read
    // only the named values, including GUID-prefixed NVRAM representations.
    auto options = IORegistryEntry::fromPath("/options", gIODTPlane);
    if (options) {
        auto properties = options->dictionaryWithProperties();
        auto keys = properties ? OSCollectionIterator::withCollection(properties) : nullptr;
        if (keys) {
            while (auto key = OSDynamicCast(OSString, keys->getNextObject())) {
                const char *name = key->getCStringNoCopy();
                const char *suffix = name;
                while (const char *colon = strchr(suffix, ':'))
                    suffix = colon + 1;
                const bool product = !strcmp(suffix, "OEMProduct");
                const bool bios = !strcmp(suffix, "OEMBIOSVersion");
                if (!product && !bios)
                    continue;
                auto object = properties->getObject(key);
                if (auto text = OSDynamicCast(OSString, object))
                    identity.add(text->getCStringNoCopy(), text->getLength(), bios);
                else if (auto data = OSDynamicCast(OSData, object))
                    identity.add(static_cast<const char *>(data->getBytesNoCopy()), data->getLength(), bios);
            }
            keys->release();
        }
        OSSafeReleaseNULL(properties);
        options->release();
    }
    setProperty("FirmwareMachineType", identity.machine);
    setProperty("FirmwareBIOSFamily", identity.bios);
    setProperty("FirmwareIdentityConflict", identity.conflict);
    constexpr unsigned checked = sizeof(ReYogaNativeProfiles) / sizeof(ReYogaNativeProfiles[0]);
    setProperty("ProfileMatchProfilesChecked", checked, 32);
    if (memcmp(bytes + 10, "LENOVO", 6)) {
        setProperty("ProfileMatchStage", "vendor_unverified");
        setProperty("ProfileMatchReason", "DSDT OEM vendor is not LENOVO; generic interfaces remain available");
        return;
    }
    const auto match = ReYogaFirmware::select(ReYogaNativeProfiles, checked, identity, oemTableID, hex);
    setProperty("ProfileMatchOEMMatches", match.oemMatches, 32);
    const auto candidate = match.profile;
    if (!candidate) {
        const char *state = "unmatched";
        const char *stage = "unsupported_firmware";
        const char *reason = "No matching machine type, BIOS family and OEM table; unsupported firmware is likely";
        switch (match.state) {
        case ReYogaFirmware::MatchState::missingIdentity:
            stage = "identity_unavailable";
            reason = "Original machine type or BIOS family unavailable; generic ACPI/WMI interfaces remain available";
            break;
        case ReYogaFirmware::MatchState::conflict:
            state = "conflict";
            stage = "identity_conflict";
            reason = "Firmware identity sources disagree; model-specific access disabled";
            break;
        case ReYogaFirmware::MatchState::ambiguous:
            state = "ambiguous";
            stage = "ambiguous";
            reason = "More than one distinct hardware profile matches; model-specific access disabled";
            break;
        default:
            break;
        }
        setProperty("ProfileMatchState", state);
        setProperty("ProfileMatchStage", stage);
        setProperty("ProfileMatchReason", reason);
        setProperty("NativeTelemetryReason", reason);
        AlwaysLog("Profile not verified: state=%s stage=%s machine=%s bios=%s oem_matches=%u",
                  state, stage, identity.machine, identity.bios, match.oemMatches);
        return;
    }
    // Identity and telemetry availability are independent: a powered-off GPU
    // or a missing second fan must not erase an otherwise identified model.
    nativeProfile = candidate;
    setProperty("HardwareProfile", candidate->id);
    setProperty("HardwareProfileName", candidate->name);
    setProperty("NativeTelemetryProfile", true);
    setProperty("ProfileMatchState", match.exact ? "exact" : match.pciMatched ? "pci_matched"
                                                                              : "identity_matched");
    setProperty("ProfileMatchStage", "identified");
    setProperty("ProfileMatchReason", match.exact ? "Reviewed AML fingerprint matched" : match.pciMatched ? "PCI subsystem ID and DSDT OEM table matched"
                                                                                                          : "Machine type and DSDT OEM table matched");
    setProperty("NativeTelemetryReason", "Sensor reads are validated individually; identity does not validate writes");
    AlwaysLog("Profile identified: id=%s machine=%s bios=%s exact=%d", candidate->id, identity.machine, identity.bios, match.exact);
}

void IdeaVPC::initBridge() {
    UInt32 bridgeID = 0;
    legionBridge = !bridgeDisabled && ec->evaluateInteger("RYID", &bridgeID) == kIOReturnSuccess &&
                   (bridgeID == 0x52590101 || bridgeID == 0x52590102);
    legionBridgeVersion = legionBridge ? bridgeID & 0xff : 0;
    setProperty("ACPIBridgeVersion", legionBridgeVersion, 32);
    if (!legionBridge)
        return;
    OSObject *identity = nullptr;
    if (ec->evaluateObject("RYPN", &identity) == kIOReturnSuccess && OSDynamicCast(OSString, identity))
        setProperty("ACPIBridgeProfile", identity);
    OSSafeReleaseNULL(identity);
    if (ec->evaluateObject("RYNM", &identity) == kIOReturnSuccess && OSDynamicCast(OSString, identity))
        setProperty("ACPIBridgeProfileName", identity);
    OSSafeReleaseNULL(identity);
    // An installed bridge is an explicit interface, but must not contradict
    // independently collected firmware identity.
    auto bridgeProfile = OSDynamicCast(OSString, getProperty("ACPIBridgeProfile"));
    auto conflict = OSDynamicCast(OSBoolean, getProperty("FirmwareIdentityConflict"));
    auto matchState = OSDynamicCast(OSString, getProperty("ProfileMatchState"));
    if (!nativeProfile || !bridgeProfile || !matchState || !matchState->isEqualTo("exact") ||
        (conflict && conflict->getValue()) || !bridgeProfile->isEqualTo(nativeProfile->id)) {
        legionBridge = false;
        legionBridgeVersion = 0;
        setProperty("ACPIBridgeVersion", static_cast<UInt64>(0), 32);
        setProperty("ACPIBridgeReason", "Bridge requires a reviewed AML fingerprint and matching firmware identity");
    }
}

bool IdeaVPC::examineWMI(IOService *provider) {
    auto feature = OSDynamicCast(OSString, provider->getProperty("Feature"));
    if (feature && feature->isEqualTo("Game Zone")) {
        wmig = OSDynamicCast(IdeaWMIGameZone, provider);
        if (wmig) {
            setProperty("Game Zone", provider);
            setProperty("LenovoFanMethod", wmig->hasFanMethod);
            setProperty("LenovoLightingMethod", wmig->hasLightingMethod);
            if (auto fans = provider->getProperty("Fan number"))
                setProperty("Fan number", fans);
            updateAll();
        }
    }
    return true;
}

IOService *IdeaVPC::initWMI(WMI *instance) {
    return ReYogaWMI::withIdeaWMI(instance);
};
