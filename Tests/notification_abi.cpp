#include "../ReYogaSMC/ReYogaSMCUserClient.h"

static_assert(kRYSMCUCOpen == 0 && kRYSMCUCClose == 1 && kRYSMCUCReadEC == 2 &&
              kRYSMCUCWriteEC == 3 && kRYSMCUCReadECName == 4 &&
              kRYSMCUCThinkFan == 5 && kRYSMCUCThinkFanCurve == 6 &&
              kRYSMCUCNumMethods == 7, "User-client selectors are a stable ABI");
static_assert(kRYSMCFanReplySize == 3 && kRYSMCFanQueryRPM == 0x100 &&
              kRYSMCFanCurveFullSpeed == 0x47, "Fan protocol values changed");

#ifdef KERNEL
static_assert(sizeof(mach_msg_header_t) == 32 && sizeof(SMCNotificationMessage) == 48,
              "Kernel notification uses pointer-sized Mach ports");
#else
static_assert(sizeof(mach_msg_header_t) == 24 && sizeof(SMCNotificationMessage) == 40,
              "User notification uses 32-bit Mach port names");
#endif
