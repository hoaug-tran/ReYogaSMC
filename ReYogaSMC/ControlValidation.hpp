// SPDX-License-Identifier: GPL-2.0-only
#ifndef ReYogaControlValidation_hpp
#define ReYogaControlValidation_hpp
namespace ReYogaControl {
constexpr bool validControlEnvelopeLengths(unsigned propertyLength, unsigned requestIDLength) {
    return propertyLength <= 64 && requestIDLength <= 64;
}
constexpr unsigned kThinkFanQueryRPM = 0x100;
constexpr unsigned kThinkFanControlOffset = 0x2f;
constexpr unsigned kThinkFanRPMOffset = 0x84;
constexpr unsigned kThinkFanSelectorOffset = 0x31;
// Curve writes expire independently of the user process and temperature reader.
struct ThinkFanLease {
    unsigned long long deadline[2]{};
    void renew(unsigned fan, unsigned long long now) { deadline[fan] = now + 6000; }
    void cancel(unsigned fan) { deadline[fan] = 0; }
    bool expired(unsigned fan, unsigned long long now) const { return deadline[fan] && now >= deadline[fan]; }
    bool active() const { return deadline[0] || deadline[1]; }
};
constexpr unsigned thinkFanRPM(unsigned char low, unsigned char high) {
    return static_cast<unsigned>(low) | static_cast<unsigned>(high) << 8;
}
constexpr bool validHPSensorStatus(unsigned status) {
    switch (status) {
    case 3:
    case 4:
    case 5:
    case 6:
    case 7:
    case 12:
    case 13:
    case 14:
    case 16:
    case 20:
    case 23:
        return false;
    default:
        return true;
    }
}

// HP WMI strings are a LE byte length followed by UTF-16LE (hp-wmi-sensors).
inline bool decodeHPWMIString(const unsigned char *bytes, unsigned length, char *output, unsigned capacity) {
    if (!bytes || length <= 2 || length > 1026 || !output || !capacity)
        return false;
    const unsigned count = bytes[0] | (static_cast<unsigned>(bytes[1]) << 8);
    if (count > length - 2 || (count & 1))
        return false;
    unsigned written = 0;
    for (unsigned offset = 2; offset < count + 2; offset += 2) {
        unsigned code = bytes[offset] | (static_cast<unsigned>(bytes[offset + 1]) << 8);
        if (!code) {
            if (offset + 2 != count + 2)
                return false;
            break;
        }
        if (code >= 0xd800 && code <= 0xdbff) {
            if (offset + 3 >= count + 2)
                return false;
            const unsigned low = bytes[offset + 2] | (static_cast<unsigned>(bytes[offset + 3]) << 8);
            if (low < 0xdc00 || low > 0xdfff)
                return false;
            code = 0x10000 + ((code - 0xd800) << 10) + low - 0xdc00;
            offset += 2;
        } else if (code >= 0xdc00 && code <= 0xdfff) {
            return false;
        }
        const unsigned size = code < 0x80 ? 1 : code < 0x800 ? 2 : code < 0x10000 ? 3 : 4;
        if (size >= capacity - written)
            return false;
        if (size == 1) output[written++] = static_cast<char>(code);
        else {
            output[written++] = static_cast<char>((size == 2 ? 0xc0 : size == 3 ? 0xe0 : 0xf0) | (code >> (6 * (size - 1))));
            for (unsigned remaining = size - 1; remaining > 0; --remaining)
                output[written++] = static_cast<char>(0x80 | ((code >> (6 * (remaining - 1))) & 0x3f));
        }
    }
    output[written] = 0;
    return true;
}

// Temperature output is milli-Celsius; fan output is RPM.
inline bool decodeHPSensor(unsigned reading, int modifier, unsigned type, unsigned units, unsigned &value) {
    if (modifier < -9 || modifier > 9 ||
        (type == 2 ? units < 2 || units > 4 : type != 12 || units != 19))
        return false;
    unsigned long long scaled = static_cast<unsigned long long>(reading) * 1000;
    while (modifier < 0) {
        scaled /= 10;
        ++modifier;
    }
    while (modifier > 0) {
        if (scaled > 0x7fffffffffffffffULL / 10)
            return false;
        scaled *= 10;
        --modifier;
    }
    long long result = static_cast<long long>(scaled);
    if (type == 2 && units == 3) {
        if (result > 0x7fffffffffffffffLL / 5)
            return false;
        result = (result - 32000) * 5 / 9;
    } else if (type == 2 && units == 4) {
        result -= 273150;
    }
    if (result < 0 || (type == 2 ? result == 0 || result >= 125000 : result > 65534000))
        return false;
    value = static_cast<unsigned>(type == 2 ? result : (result + 500) / 1000);
    return true;
}

constexpr bool validThinkFanLevel(unsigned value) {
    return value <= 7 || value == 0x47 || value == 0x80 || value == 0x84;
}
enum class ThinkFanResult { ok,
                            invalid,
                            transportFailed,
                            restoreFailed,
                            readbackMismatch };

struct ThinkFanState {
    unsigned modifiedMask{0};
    bool selectorRestorePending{false};
    unsigned char originalSelector{0};
    unsigned pollStatus[2]{0, 0};
    bool pollStatusChanged(unsigned fan, unsigned status) {
        if (fan > 1 || pollStatus[fan] == status)
            return false;
        pollStatus[fan] = status;
        return true;
    }
};

template <typename Read, typename Write>
bool restoreThinkFanSelector(ThinkFanState &state, Read read, Write write) {
    if (!state.selectorRestorePending)
        return true;
    unsigned char current = 0;
    if (!read(kThinkFanSelectorOffset, current))
        return false;
    if ((current & 1) != state.originalSelector) {
        // Preserve unrelated EC bits that firmware may have changed meanwhile.
        if (!write(kThinkFanSelectorOffset, (current & 0xfe) | state.originalSelector) ||
            !read(kThinkFanSelectorOffset, current) || (current & 1) != state.originalSelector)
            return false;
    }
    state.selectorRestorePending = false;
    return true;
}

template <typename Read, typename Write>
ThinkFanResult transactThinkFan(unsigned fan, unsigned target, unsigned char output[3],
                                bool hasSelector, ThinkFanState &state, Read read, Write write) {
    if (!output || fan > 1 || (fan && !hasSelector) ||
        (target != kThinkFanQueryRPM && !validThinkFanLevel(target)))
        return ThinkFanResult::invalid;
    const bool automatic = target == 0x80 || target == 0x84;
    if (state.selectorRestorePending && (!automatic || !restoreThinkFanSelector(state, read, write)))
        return ThinkFanResult::restoreFailed;
    unsigned char original = 0;
    if (hasSelector && !read(kThinkFanSelectorOffset, original))
        return ThinkFanResult::transportFailed;
    const unsigned char selected = (original & 0xfe) | fan;
    const bool changed = hasSelector && selected != original;
    bool valid = true;
    if (changed) {
        state.originalSelector = original & 1;
        state.selectorRestorePending = true;
        valid = write(kThinkFanSelectorOffset, selected);
        unsigned char actual = 0;
        if (valid)
            valid = read(kThinkFanSelectorOffset, actual) && (actual & 1) == fan;
    }
    if (valid && target != kThinkFanQueryRPM) {
        // A failed transport can still have applied the manual setting.
        state.modifiedMask |= 1U << fan;
        valid = write(kThinkFanControlOffset, static_cast<unsigned char>(target));
    }
    unsigned char sample[3]{};
    if (valid)
        valid = read(kThinkFanRPMOffset, sample[0]);
    if (valid)
        valid = read(kThinkFanRPMOffset + 1, sample[1]);
    if (valid)
        valid = read(kThinkFanControlOffset, sample[2]);
    if (!restoreThinkFanSelector(state, read, write))
        return ThinkFanResult::restoreFailed;
    if (!valid)
        return ThinkFanResult::transportFailed;
    // 0xffff means unavailable RPM, not an unsuccessful control transaction.
    if ((sample[2] & 0x38) || (sample[2] & 0xc0) == 0xc0)
        return ThinkFanResult::readbackMismatch;
    if (target != kThinkFanQueryRPM) {
        const bool confirmed = target == 0x47 ? (sample[2] & 0x40) != 0 : (target == 0x80 || target == 0x84) ? (sample[2] & 0x80) != 0
                                                                                                             : sample[2] == target;
        if (!confirmed)
            return ThinkFanResult::readbackMismatch;
    }
    if (automatic)
        state.modifiedMask &= ~(1U << fan);
    for (unsigned i = 0; i < 3; ++i)
        output[i] = sample[i];
    return ThinkFanResult::ok;
}

constexpr bool validECSpan(unsigned long long offset, unsigned long long size) {
    return offset < 0x100 && size != 0 && size <= 0x100 - offset;
}
constexpr unsigned thresholdPercent(unsigned raw, bool stop) {
    return stop && (raw & 0xff) == 0 ? 100 : raw & 0xff;
}
constexpr bool validThresholdState(unsigned raw, bool stop) {
    return (raw & (1U << 8)) && !(raw & (1U << 31)) && thresholdPercent(raw, stop) <= (stop ? 100U : 99U);
}
constexpr bool validThresholdTarget(unsigned target, bool start, unsigned other) {
    return start ? target <= 99 && other >= 1 && other <= 100 && target <= other : target >= 1 && target <= 100 && other <= 99 && target >= other;
}
} // namespace ReYogaControl
#endif
