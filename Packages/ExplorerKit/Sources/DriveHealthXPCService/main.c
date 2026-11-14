/* Staged, unregistered source only. A future reviewed target must supply this
 * literal requirement at compile time; environment and IPC cannot configure it.
 * Without it, this executable never installs a listener or acquires a device. */
#ifndef TH_HEALTH_XPC_PARENT_REQUIREMENT
int main(void) { return 78; }
#else

#include "DriveHealthNative.h"
#include <dispatch/dispatch.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <xpc/xpc.h>

static dispatch_queue_t control_queue, acquisition_queue;
/* Accessed only on control_queue. This service admits one request in its entire
 * process lifetime. Never reopen admission after either success or uncertainty. */
static bool acquisition_admitted;

/* Every caller has admitted one request and returned from native acquisition.
 * The explicit transaction keeps the service alive after its automatic reply
 * transaction ends. No error path can release it while native work is active. */
static void finish_admitted(xpc_object_t reply, xpc_object_t request,
                            xpc_connection_t peer, int status) {
    xpc_release(reply);
    xpc_release(request);
    xpc_release(peer);
    xpc_transaction_end();
    _Exit(status);
}

static void accept_peer(xpc_connection_t peer) {
    /* Public macOS12+ declaration: <xpc/connection.h>. Apply once, before
     * activation, to authenticate received messages rather than looking up PID.
     * The app must independently authenticate this service before sending. */
    if (xpc_connection_set_peer_code_signing_requirement(peer, TH_HEALTH_XPC_PARENT_REQUIREMENT) != 0) {
        /* XPC peers must be activated before final release. Reject every
         * event on this path; a bad requirement never reaches acquisition. */
        xpc_connection_set_event_handler(peer, ^(xpc_object_t ignored) { (void)ignored; });
        xpc_connection_activate(peer);
        xpc_connection_cancel(peer);
        return;
    }
    xpc_connection_set_target_queue(peer, control_queue);
    __block bool used = false;
    __block bool invalidated = false;
    __block bool native_returned = false;
    __block bool terminal_sent = false;
    __block THWireRequest admitted_request = {0};
    __block xpc_object_t held_request = NULL, held_reply = NULL;
    __block xpc_connection_t held_peer = NULL;
    xpc_connection_set_event_handler(peer, ^(xpc_object_t message) {
        if (xpc_get_type(message) != XPC_TYPE_DICTIONARY) {
            invalidated = true;
            if (used && native_returned)
                finish_admitted(held_reply, held_request, held_peer, 74);
            if (message != XPC_ERROR_CONNECTION_INVALID) xpc_connection_cancel(peer);
            return;
        }
        if (used) {
            /* ACK is the only permitted message after the one native request.
             * It proves the authenticated parent received the nonce reply,
             * not merely that the service queued or sent it. */
            xpc_object_t ack = xpc_dictionary_get_value(message, "ack");
            if (native_returned && terminal_sent && !invalidated
                && xpc_dictionary_get_count(message) == 1
                && ack && xpc_get_type(ack) == XPC_TYPE_DATA
                && xpc_data_get_length(ack) == sizeof(admitted_request.nonce)
                && xpc_data_get_bytes_ptr(ack)
                && memcmp(xpc_data_get_bytes_ptr(ack), admitted_request.nonce,
                          sizeof(admitted_request.nonce)) == 0) {
                finish_admitted(held_reply, held_request, held_peer, EXIT_SUCCESS);
            }
            invalidated = true;
            xpc_connection_cancel(peer);
            if (native_returned)
                finish_admitted(held_reply, held_request, held_peer, 74);
            return;
        }
        xpc_object_t payload = xpc_dictionary_get_value(message, "request");
        THWireRequest request;
        if (acquisition_admitted || xpc_dictionary_get_count(message) != 1
            || !payload || xpc_get_type(payload) != XPC_TYPE_DATA
            || !th_wire_decode_request(xpc_data_get_bytes_ptr(payload), xpc_data_get_length(payload), &request)) {
            xpc_connection_cancel(peer);
            return;
        }
        xpc_object_t reply = xpc_dictionary_create_reply(message);
        if (!reply) { xpc_connection_cancel(peer); return; }
        xpc_transaction_begin();
        used = true; acquisition_admitted = true;
        admitted_request = request;
        held_request = xpc_retain(message);
        held_reply = reply;
        held_peer = xpc_retain(peer);
        dispatch_async(acquisition_queue, ^{
            THNativeOutcome outcome;
            th_native_read_once(request.selected_media, request.outer_whole,
                                request.block_boundary, request.generation, &outcome);
            /* Retain request/reply and the explicit XPC transaction through
             * native return and terminal handling, even if the peer cancels.
             * XPC cancellation cannot preempt this synchronous native call. */
            uint8_t bytes[THResponseBytes];
            int encoded = th_wire_encode_response(&request, &outcome, bytes, sizeof(bytes));
            if (encoded) xpc_dictionary_set_data(reply, "reply", bytes, sizeof(bytes));
            dispatch_async(control_queue, ^{
                native_returned = true;
                if (!encoded || invalidated)
                    finish_admitted(held_reply, held_request, held_peer, 74);
                /* Send on the connection carried by the reply context. The
                 * explicit transaction remains until an authenticated ACK;
                 * a send barrier would not establish remote receipt. */
                xpc_connection_t response_peer = xpc_dictionary_get_remote_connection(reply);
                if (!response_peer)
                    finish_admitted(held_reply, held_request, held_peer, 74);
                xpc_connection_send_message(response_peer, reply);
                terminal_sent = true;
                /* This starts only after native return. Lost ACKs cannot keep
                 * an idle service or its retained reply alive indefinitely. */
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC), control_queue, ^{
                    if (terminal_sent)
                        finish_admitted(held_reply, held_request, held_peer, 74);
                });
            });
        });
    });
    xpc_connection_activate(peer);
}

int main(void) {
    if (strlen(TH_HEALTH_XPC_PARENT_REQUIREMENT) == 0) return 78;
    control_queue = dispatch_queue_create("local.traverse.health-xpc-control", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_attr_t utility = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
    acquisition_queue = dispatch_queue_create("local.traverse.health-xpc-acquisition", utility);
    xpc_main(accept_peer);
}
#endif
