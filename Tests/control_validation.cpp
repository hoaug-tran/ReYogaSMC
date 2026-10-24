// Compile-time tests exercise the same validation functions used by the kext.
#include "../ReYogaSMC/ControlValidation.hpp"
using namespace ReYogaControl;
static_assert(validECSpan(0, 256), "full standard EC span");
static_assert(validECSpan(255, 1), "last EC byte");
static_assert(!validECSpan(256, 1), "offset overflow");
static_assert(!validECSpan(255, 2), "range overflow");
static_assert(!validECSpan(0, 0), "empty read");
static_assert(!validECSpan(~0ULL, 1), "64-bit offset must not truncate");
static_assert(!validECSpan(1, ~0ULL), "64-bit size must not wrap");
static_assert(thresholdPercent(0x100, true) == 100, "stop zero means full charge");
static_assert(thresholdPercent(0x100, false) == 0, "start zero remains zero");
static_assert(validThresholdState(0x100, false), "supported default start");
static_assert(validThresholdState(0x100, true), "supported default stop");
static_assert(!validThresholdState(50, true), "missing capability bit");
static_assert(!validThresholdState(0x80000132, true), "firmware error bit");
static_assert(!validThresholdState(0x1ff, true), "invalid percent");
static_assert(!validThresholdState(0x164, false), "start cannot reach 100");
constexpr bool thresholdMatrix() {
    for (unsigned target = 0; target <= 110; ++target)
        for (unsigned other = 0; other <= 110; ++other) {
            if (validThresholdTarget(target, true, other) !=
                (target < 100 && other > 0 && other <= 100 && target <= other)) return false;
            if (validThresholdTarget(target, false, other) !=
                (target > 0 && target <= 100 && other < 100 && target >= other)) return false;
        }
    return true;
}
static_assert(thresholdMatrix(), "threshold ranges and ordering for every boundary combination");
