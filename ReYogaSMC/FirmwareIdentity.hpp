// SPDX-License-Identifier: GPL-2.0-only
#ifndef ReYogaFirmwareIdentity_hpp
#define ReYogaFirmwareIdentity_hpp

#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include "ReYogaFirmwareProfiles.hpp"
#include "SensorDescriptors.hpp"

namespace ReYogaFirmware {
inline char upper(char c) { return c >= 'a' && c <= 'z' ? c - 'a' + 'A' : c; }
inline bool alphanumeric(char c) { return (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'); }

struct Identity {
    char machine[5]{};
    char bios[5]{};
    bool conflict{false};
    uint32_t pciSubsystems[32]{};
    unsigned pciCount{0};

    void addPCI(uint32_t vendor, uint32_t device) {
        if (vendor != 0x17aa || device > 0xffff)
            return;
        const uint32_t value = vendor << 16 | device;
        for (unsigned i = 0; i < pciCount; ++i)
            if (pciSubsystems[i] == value)
                return;
        if (pciCount < 32)
            pciSubsystems[pciCount++] = value;
    }

    void addSubsystem(const char *text, size_t length) {
        if (!text || (length != 8 && length != 9))
            return;
        uint32_t vendor = 0;
        uint32_t device = 0;
        const size_t devOffset = (length == 9 && text[4] == ':') ? 5 : 4;
        if (length == 9 && text[4] != ':')
            return;
        for (unsigned i = 0; i < 4; ++i) {
            const char c = upper(text[i]);
            if (c >= '0' && c <= '9')
                vendor = (vendor << 4) | (c - '0');
            else if (c >= 'A' && c <= 'F')
                vendor = (vendor << 4) | (c - 'A' + 10);
            else
                return;
        }
        for (unsigned i = 0; i < 4; ++i) {
            const char c = upper(text[devOffset + i]);
            if (c >= '0' && c <= '9')
                device = (device << 4) | (c - '0');
            else if (c >= 'A' && c <= 'F')
                device = (device << 4) | (c - 'A' + 10);
            else
                return;
        }
        addPCI(vendor, device);
    }

    bool matchesPCI(const char *ids) const {
        if (!ids)
            return false;
        while (*ids) {
            const char *end = strchr(ids, '|');
            const size_t length = end ? static_cast<size_t>(end - ids) : strlen(ids);
            uint32_t value = 0;
            bool valid = length == 9 && ids[4] == ':';
            for (size_t i = 0; valid && i < length; ++i) {
                if (i == 4)
                    continue;
                const char c = upper(ids[i]);
                if (c >= '0' && c <= '9')
                    value = value << 4 | (c - '0');
                else if (c >= 'A' && c <= 'F')
                    value = value << 4 | (c - 'A' + 10);
                else
                    valid = false;
            }
            for (unsigned i = 0; valid && i < pciCount; ++i)
                if (pciSubsystems[i] == value)
                    return true;
            if (!end)
                break;
            ids = end + 1;
        }
        return false;
    }

    void add(const char *value, size_t length, bool isBIOS) {
        if (!value || length < 4 || length > 256)
            return;
        while (length && (*value == ' ' || *value == '\t')) {
            ++value;
            --length;
        }
        if (length < 4)
            return;
        char code[5]{};
        for (unsigned i = 0; i < 4; ++i) {
            code[i] = upper(value[i]);
            if (!alphanumeric(code[i]))
                return;
        }
        if (!strncmp(code, "MBP", 3) || !strncmp(code, "MAC", 3) ||
            !strncmp(code, "APPL", 4) || !strncmp(code, "IMAC", 4))
            return;
        if (!isBIOS && !(code[0] >= '0' && code[0] <= '9' && code[1] >= '0' && code[1] <= '9'))
            return;
        if (isBIOS && (length < 5 || value[4] < '0' || value[4] > '9'))
            return;
        char *destination = isBIOS ? bios : machine;
        if (destination[0] && strcmp(destination, code))
            conflict = true;
        else
            memcpy(destination, code, sizeof(code));
    }
};

inline bool readSMBIOS(const uint8_t *bytes, size_t size, Identity &identity) {
    if (!bytes || size < 6 || size > 1024 * 1024)
        return false;
    Identity parsed;
    size_t offset = 0;
    while (offset < size) {
        if (size - offset < 4)
            return false;
        size_t length = bytes[offset + 1];
        if (length < 4 || length > size - offset)
            return false;
        size_t end = offset + length;
        while (end + 1 < size && (bytes[end] || bytes[end + 1]))
            ++end;
        if (end + 1 >= size)
            return false;
        const unsigned type = bytes[offset];
        constexpr unsigned indexOffset = 5;
        if ((type == 0 || type == 1) && length > indexOffset) {
            auto stringAt = [&](unsigned wanted, size_t &stringLength) -> const char * {
                size_t start = offset + length;
                for (unsigned index = 1; wanted && start < end; ++index) {
                    size_t next = start;
                    while (next < end && bytes[next])
                        ++next;
                    if (index == wanted) {
                        stringLength = next - start;
                        return reinterpret_cast<const char *>(bytes + start);
                    }
                    start = next + 1;
                }
                return nullptr;
            };
            size_t vendorLength = 0;
            const char *vendor = stringAt(bytes[offset + 4], vendorLength);
            bool lenovo = vendor && vendorLength == 6;
            for (unsigned i = 0; lenovo && i < 6; ++i)
                lenovo = upper(vendor[i]) == "LENOVO"[i];
            if (lenovo) {
                if (type == 0) {
                    size_t stringLength = 0;
                    const char *text = stringAt(bytes[offset + indexOffset], stringLength);
                    if (text)
                        parsed.add(text, stringLength, true);
                } else if (type == 1) {
                    constexpr unsigned offsets[] = {0x05, 0x06, 0x19};
                    for (unsigned off : offsets) {
                        if (length > off && !parsed.machine[0]) {
                            size_t stringLength = 0;
                            const char *text = stringAt(bytes[offset + off], stringLength);
                            if (text) {
                                parsed.add(text, stringLength, false);
                                if (!parsed.machine[0] && stringLength >= 4) {
                                    for (size_t s = 0; s + 4 <= stringLength; ++s) {
                                        if (text[s] >= '0' && text[s] <= '9' && text[s + 1] >= '0' && text[s + 1] <= '9') {
                                            parsed.add(text + s, 4, false);
                                            if (parsed.machine[0])
                                                break;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        offset = end + 2;
        if (type == 127)
            break;
    }
    if (parsed.machine[0])
        identity.add(parsed.machine, 4, false);
    if (parsed.bios[0]) {
        if (identity.bios[0] && strcmp(identity.bios, parsed.bios))
            identity.conflict = true;
        else
            memcpy(identity.bios, parsed.bios, sizeof(parsed.bios));
    }
    identity.conflict = identity.conflict || parsed.conflict;
    return true;
}

inline void readDSDT(const uint8_t *bytes, size_t size, Identity &identity) {
    if (!bytes || size < 36 || size > 4 * 1024 * 1024)
        return;
    for (size_t i = 36; i + 4 <= size; ++i) {
        if (bytes[i] == '_' && bytes[i + 1] == 'S' && bytes[i + 2] == 'U' && bytes[i + 3] == 'B') {
            const size_t limit = (i + 256 < size) ? (i + 256) : size;
            for (size_t j = i + 4; j < limit; ++j) {
                if (bytes[j] == 0x0D && j + 1 < limit) {
                    const char *str = reinterpret_cast<const char *>(bytes + j + 1);
                    size_t len = 0;
                    while (j + 1 + len < limit && str[len] && len <= 16)
                        ++len;
                    if (j + 1 + len < limit && bytes[j + 1 + len] == '\0') {
                        if (len == 8 || len == 9)
                            identity.addSubsystem(str, len);
                        j += len + 1;
                    }
                }
                if (bytes[j] == 0x0C && j + 5 <= limit) {
                    const uint32_t val = static_cast<uint32_t>(bytes[j + 1]) |
                                         static_cast<uint32_t>(bytes[j + 2]) << 8 |
                                         static_cast<uint32_t>(bytes[j + 3]) << 16 |
                                         static_cast<uint32_t>(bytes[j + 4]) << 24;
                    if ((val & 0xffff) == 0x17aa)
                        identity.addPCI(0x17aa, (val >> 16) & 0xffff);
                    j += 4;
                }
            }
        }
    }
}

enum class MatchState { matched,
                        missingIdentity,
                        conflict,
                        unsupported,
                        ambiguous };
struct Match {
    const ReYogaNativeProfile *profile{nullptr};
    MatchState state{MatchState::unsupported};
    bool pciMatched{false};
    unsigned oemMatches{0};
};

inline Match select(const ReYogaNativeProfile *profiles, size_t count, const Identity &identity,
                    const char *oem) {
    Match result;
    if (!profiles || !count || !oem || !oem[0])
        return result;
    if (identity.conflict) {
        result.state = MatchState::conflict;
        return result;
    }
    const bool complete = identity.machine[0] && identity.bios[0];
    bool conflictingEvidence = false;
    for (size_t i = 0; i < count; ++i) {
        const auto &profile = profiles[i];
        if (strcmp(oem, profile.oemTableID))
            continue;
        ++result.oemMatches;
        const bool pciMatch = identity.matchesPCI(profile.pciSubsystemIDs);
        const bool machineMismatch = identity.machine[0] && strcmp(identity.machine, profile.machineType);
        const bool biosMismatch = identity.bios[0] && strcmp(identity.bios, profile.biosFamily);
        if (pciMatch && (machineMismatch || biosMismatch)) {
            bool compatibleRow = false;
            for (size_t j = 0; j < count; ++j) {
                const auto &other = profiles[j];
                if (!strcmp(profile.id, other.id) &&
                    (!identity.machine[0] || !strcmp(identity.machine, other.machineType)) &&
                    (!identity.bios[0] || !strcmp(identity.bios, other.biosFamily)))
                    compatibleRow = true;
            }
            if (!compatibleRow)
                conflictingEvidence = true;
        }
        if (machineMismatch || biosMismatch || (!identity.machine[0] && !pciMatch))
            continue;
        if (result.profile && strcmp(result.profile->id, profile.id)) {
            result.state = MatchState::ambiguous;
            result.profile = nullptr;
            return result;
        }
        result.profile = &profile;
        result.pciMatched = result.pciMatched || pciMatch;
    }
    if (conflictingEvidence) {
        result.profile = nullptr;
        result.state = MatchState::conflict;
    } else if (result.profile)
        result.state = MatchState::matched;
    else
        result.state = complete ? MatchState::unsupported : MatchState::missingIdentity;
    return result;
}

inline bool validSample(unsigned sensor, uint32_t raw, unsigned scale, uint32_t &value) {
    if (!scale || raw > UINT32_MAX / scale)
        return false;
    value = raw * scale;
    return sensor < ReYogaSensor::CPU ? value < 0xFFFF : value > 0 && value < 125;
}
} // namespace ReYogaFirmware
#endif
