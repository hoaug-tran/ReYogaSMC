// SPDX-License-Identifier: GPL-2.0-only
#ifndef ReYogaSensorDescriptors_hpp
#define ReYogaSensorDescriptors_hpp

namespace ReYogaSensor {
// Matches the generated profile fields/scales arrays; do not reorder.
enum SensorIndex : unsigned { Fan1 = 0,
                              Fan2 = 1,
                              CPU = 2,
                              GPU = 3,
                              Count = 4 };
struct Descriptor {
    const char *property;
    const char *bridgeMethod;
    bool isFan;
};
static constexpr Descriptor descriptors[Count] = {
    {"Fan1RPM", "RYF0", true},
    {"Fan2RPM", "RYF1", true},
    {"CPUTemp", "RYT0", false},
    {"GPUTemp", "RYT1", false}};
} // namespace ReYogaSensor

#endif
