// SPDX-License-Identifier: GPL-2.0-only
//
// ReYogaSMCUserClient.h
// Shared kernel/userspace wire protocol. Keep this header C-compatible.
//
// Original work: Copyright (c) 2020 Zhen.

#ifndef REYOGA_SMC_USER_CLIENT_H
#define REYOGA_SMC_USER_CLIENT_H

#include <mach/message.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// These selector numbers are part of the public ABI. Never reorder them.
enum {
    kRYSMCUCOpen = 0,          // No inputs or outputs.
    kRYSMCUCClose = 1,         // No inputs or outputs.
    kRYSMCUCReadEC = 2,        // Scalar input: offset; variable structure output.
    kRYSMCUCWriteEC = 3,       // Reserved: disabled; variable structure input.
    kRYSMCUCReadECName = 4,    // Reserved pending a verified ACPI read allowlist.
    kRYSMCUCThinkFan = 5,      // Scalar inputs: fan, command; 3-byte structure output.
    kRYSMCUCThinkFanCurve = 6, // Same shape; watchdog-controlled levels.
    kRYSMCUCNumMethods = 7
};

// User-client protocol values. These are NOT raw EC register offsets.
enum {
    kRYSMCMaxFanIndex = 1,
    kRYSMCFanReplySize = 3,
    kRYSMCFanQueryRPM = 0x100,
    kRYSMCFanCurveFullSpeed = 0x47,
    kRYSMCNotificationType = 0
};

// Wire layout, shared between kernel and userspace.
// 'ref' is explicitly 64-bit; do not depend on SDK typedef differences.
typedef struct SMCNotificationMessage {
    mach_msg_header_t header;
    uint32_t event;
    uint32_t data;
    uint64_t ref;
} SMCNotificationMessage;

#ifdef __cplusplus
} // extern "C"

#if defined(__LP64__)
// Kernel port fields are pointers; userspace port fields are 32-bit names.
// The Mach send path translates the header; payload layout stays identical.
static_assert(offsetof(SMCNotificationMessage, event) == sizeof(mach_msg_header_t) &&
                  offsetof(SMCNotificationMessage, data) == sizeof(mach_msg_header_t) + 4 &&
                  offsetof(SMCNotificationMessage, ref) == sizeof(mach_msg_header_t) + 8,
              "SMCNotificationMessage ABI offsets have changed");
static_assert(sizeof(SMCNotificationMessage) == sizeof(mach_msg_header_t) + 16,
              "SMCNotificationMessage ABI layout has changed");
#endif
#endif

#endif // REYOGA_SMC_USER_CLIENT_H
