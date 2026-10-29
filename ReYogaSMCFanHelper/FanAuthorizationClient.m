#import "FanAuthorizationClient.h"
#import <IOKit/IOReturn.h>
#import <xpc/xpc.h>
#import "../ReYogaSMC/ReYogaSMCUserClient.h"

void ReYogaAuthorizeFan(uint64_t serviceID, void (^completion)(int32_t)) {
    dispatch_queue_t queue = dispatch_queue_create("org.reyoga.fan-authorization", DISPATCH_QUEUE_SERIAL);
    xpc_connection_t connection = xpc_connection_create_mach_service(
        "org.reyoga.ReYogaSMC.FanAuthorization", queue, XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
    if (!connection) { completion(kIOReturnNoMemory); return; }
    __block BOOL finished = NO;
    void (^finish)(int32_t) = ^(int32_t status) {
        if (finished) return;
        finished = YES;
        xpc_connection_cancel(connection);
        completion(status);
    };
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_ERROR) finish(kIOReturnNotFound);
    });
    xpc_connection_resume(connection);
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(message, "version", kRYSMCFanAuthorizationVersion);
    xpc_dictionary_set_uint64(message, "service", serviceID);
    xpc_connection_send_message_with_reply(connection, message, queue, ^(xpc_object_t reply) {
        if (xpc_get_type(reply) != XPC_TYPE_DICTIONARY ||
            xpc_connection_get_euid(connection) != 0 ||
            xpc_dictionary_get_uint64(reply, "version") != kRYSMCFanAuthorizationVersion ||
            !xpc_dictionary_get_value(reply, "status") ||
            xpc_get_type(xpc_dictionary_get_value(reply, "status")) != XPC_TYPE_INT64) {
            finish(kIOReturnNotPermitted);
            return;
        }
        int64_t status = xpc_dictionary_get_int64(reply, "status");
        finish(status < INT32_MIN || status > INT32_MAX ? kIOReturnBadArgument : (int32_t)status);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), queue, ^{ finish(kIOReturnTimeout); });
}
