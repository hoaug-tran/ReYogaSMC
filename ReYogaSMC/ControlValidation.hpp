// SPDX-License-Identifier: GPL-2.0-only
#ifndef ReYogaControlValidation_hpp
#define ReYogaControlValidation_hpp
namespace ReYogaControl {
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
