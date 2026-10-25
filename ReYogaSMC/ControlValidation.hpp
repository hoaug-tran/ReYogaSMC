// SPDX-License-Identifier: GPL-2.0-only
#ifndef ReYogaControlValidation_hpp
#define ReYogaControlValidation_hpp
namespace ReYogaControl {
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
