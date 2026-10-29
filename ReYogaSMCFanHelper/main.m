// Root broker delegates only bounded fan access to an authenticated app session.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <IOKit/IOKitLib.h>
#import <bsm/libbsm.h>
#import <xpc/xpc.h>
#include <unistd.h>
#include <stdlib.h>
#import "../ReYogaSMC/ReYogaSMCUserClient.h"

// Available since macOS 10.12; some SDKs omit this libxpc declaration.
extern void xpc_connection_get_audit_token(xpc_connection_t, audit_token_t *);

static BOOL authenticated(audit_token_t token, SecRequirementRef requirement, uid_t uid) {
    if (audit_token_to_euid(token) != uid || audit_token_to_auid(token) != uid) return NO;
    NSData *audit = [NSData dataWithBytes:&token length:sizeof(token)];
    NSDictionary *attributes = @{(__bridge NSString *)kSecGuestAttributeAudit: audit};
    SecCodeRef guest = NULL;
    OSStatus status = SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)attributes,
                                                    kSecCSDefaultFlags, &guest);
    if (status != errSecSuccess || !guest) return NO;
    status = SecCodeCheckValidity(guest, kSecCSStrictValidate, requirement);
    CFRelease(guest);
    return status == errSecSuccess;
}

static IOReturn authorize(uint64_t serviceID, audit_token_t token) {
    if (!serviceID) return kIOReturnBadArgument;
    io_service_t service = IOServiceGetMatchingService(MACH_PORT_NULL, IORegistryEntryIDMatching(serviceID));
    if (!service) return kIOReturnNotAttached;
    CFTypeRef fork = IORegistryEntryCreateCFProperty(service, CFSTR("ForkName"), kCFAllocatorDefault, 0);
    CFTypeRef version = IORegistryEntryCreateCFProperty(service, CFSTR("ThinkFanAuthorizationVersion"), kCFAllocatorDefault, 0);
    BOOL valid = fork && CFEqual(fork, CFSTR("ReYogaSMC")) && version &&
        CFGetTypeID(version) == CFNumberGetTypeID() && [(__bridge NSNumber *)version unsignedIntValue] == kRYSMCFanAuthorizationVersion;
    if (fork) CFRelease(fork);
    if (version) CFRelease(version);
    io_connect_t connection = IO_OBJECT_NULL;
    IOReturn status = valid ? IOServiceOpen(service, mach_task_self(), 0, &connection) : kIOReturnUnsupported;
    IOObjectRelease(service);
    if (status != kIOReturnSuccess) return status;
    // Do not claim the provider or subscribe to events: the GUI owns that session.
    status = IOConnectCallStructMethod(connection, kRYSMCUCAuthorizeThinkFan, &token, sizeof(token), NULL, NULL);
    IOServiceClose(connection);
    return status;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (geteuid() != 0 || argc != 3) return 1;
        NSString *text = [NSString stringWithUTF8String:argv[1]];
        char *end = NULL;
        unsigned long parsed = strtoul(argv[2], &end, 10);
        if (!end || *end || parsed == 0 || parsed >= UINT32_MAX) return 1;
        uid_t uid = (uid_t)parsed;
        SecRequirementRef requirement = NULL;
        if (!text || SecRequirementCreateWithString((__bridge CFStringRef)text, kSecCSDefaultFlags, &requirement) != errSecSuccess) return 1;
        dispatch_queue_t queue = dispatch_queue_create("org.reyoga.fan-broker", DISPATCH_QUEUE_SERIAL);
        xpc_connection_t listener = xpc_connection_create_mach_service(
            "org.reyoga.ReYogaSMC.FanAuthorization", queue, XPC_CONNECTION_MACH_SERVICE_LISTENER);
        if (!listener) { CFRelease(requirement); return 1; }
        xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
            if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) return;
            xpc_connection_set_target_queue(peer, queue);
            xpc_connection_set_event_handler(peer, ^(xpc_object_t request) {
                @autoreleasepool {
                    if (xpc_get_type(request) != XPC_TYPE_DICTIONARY) return;
                    xpc_object_t reply = xpc_dictionary_create_reply(request);
                    if (!reply) { xpc_connection_cancel(peer); return; }
                    audit_token_t token = {};
                    // Revalidate live peer code on every request; never trust a supplied PID.
                    xpc_connection_get_audit_token(peer, &token);
                    IOReturn status = kIOReturnNotPermitted;
                    if (xpc_dictionary_get_count(request) == 2 &&
                        xpc_dictionary_get_uint64(request, "version") == kRYSMCFanAuthorizationVersion &&
                        authenticated(token, requirement, uid)) {
                        status = authorize(xpc_dictionary_get_uint64(request, "service"), token);
                    }
                    xpc_dictionary_set_uint64(reply, "version", kRYSMCFanAuthorizationVersion);
                    xpc_dictionary_set_int64(reply, "status", (int32_t)status);
                    xpc_connection_send_message(peer, reply);
                }
            });
            xpc_connection_resume(peer);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), queue, ^{ xpc_connection_cancel(peer); });
        });
        xpc_connection_resume(listener);
        dispatch_main();
    }
}
