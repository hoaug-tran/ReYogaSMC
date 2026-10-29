#import <Foundation/Foundation.h>
#include <stdint.h>

// Completion runs once on a private queue, including service failure and timeout.
void ReYogaAuthorizeFan(uint64_t serviceID, void (^completion)(int32_t status));
