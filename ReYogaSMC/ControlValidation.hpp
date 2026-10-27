// SPDX-License-Identifier: GPL-2.0-only
#ifndef ReYogaControlValidation_hpp
#define ReYogaControlValidation_hpp
namespace ReYogaControl {
constexpr bool validHPSensorStatus(unsigned status) {
    switch (status) {
        case 3: case 4: case 5: case 6: case 7:
        case 12: case 13: case 14: case 16:
        case 20: case 23:
            return false;
        default:
            return true;
    }
}

// Temperature output is milli-Celsius; fan output is RPM.
inline bool decodeHPSensor(unsigned reading, int modifier, unsigned type, unsigned units, unsigned &value) {
    if (modifier < -9 || modifier > 9 ||
        (type == 2 ? units < 2 || units > 4 : type != 12 || units != 19)) return false;
    unsigned long long scaled = static_cast<unsigned long long>(reading) * 1000;
    while (modifier < 0) { scaled /= 10; ++modifier; }
    while (modifier > 0) {
        if (scaled > 0x7fffffffffffffffULL / 10) return false;
        scaled *= 10;
        --modifier;
    }
    long long result = static_cast<long long>(scaled);
    if (type == 2 && units == 3) {
        if (result > 0x7fffffffffffffffLL / 5) return false;
        result = (result - 32000) * 5 / 9;
    } else if (type == 2 && units == 4) {
        result -= 273150;
    }
    if (result < 0 || (type == 2 ? result == 0 || result >= 125000 : result > 65534000)) return false;
    value = static_cast<unsigned>(type == 2 ? result : (result + 500) / 1000);
    return true;
}

constexpr bool validThinkFanLevel(unsigned value) {
    return value <= 7 || value == 0x47 || value == 0x80 || value == 0x84;
}
enum class ThinkFanResult { ok, invalid, transportFailed, restoreFailed, unavailable, readbackMismatch };

template <typename Read, typename Write>
ThinkFanResult transactThinkFan(unsigned fan, unsigned target, unsigned char output[3], Read read, Write write) {
    if (!output || fan > 1 || (target != 0x100 && !validThinkFanLevel(target))) return ThinkFanResult::invalid;
    unsigned char original = 0;
    if (!read(0x31, original)) return ThinkFanResult::transportFailed;
    const unsigned char selected = (original & 0xfe) | fan;
    const bool changed = selected != original;
    bool valid = !changed || write(0x31, selected);
    if (valid && target != 0x100) valid = write(0x2f, static_cast<unsigned char>(target));
    unsigned char sample[3] {};
    if (valid) valid = read(0x84, sample[0]);
    if (valid) valid = read(0x85, sample[1]);
    if (valid) valid = read(0x2f, sample[2]);
    if (changed && !write(0x31, original)) return ThinkFanResult::restoreFailed;
    if (!valid) return ThinkFanResult::transportFailed;
    if (sample[0] == 0xff && sample[1] == 0xff) return ThinkFanResult::unavailable;
    if (target != 0x100) {
        const bool confirmed = target == 0x47 ? (sample[2] & 0x40) != 0 :
            (target == 0x80 || target == 0x84) ? (sample[2] & 0x80) != 0 : sample[2] == target;
        if (!confirmed) return ThinkFanResult::readbackMismatch;
    }
    for (unsigned i = 0; i < 3; ++i) output[i] = sample[i];
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
    return start ? target <= 99 && other >= 1 && other <= 100 && target <= other :
        target >= 1 && target <= 100 && other <= 99 && target >= other;
}
}
#endif
