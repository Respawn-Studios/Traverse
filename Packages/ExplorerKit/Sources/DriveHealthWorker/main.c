#include "DriveHealthNative.h"
#include <errno.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

static int read_request(uint8_t bytes[THRequestBytes]) {
    size_t offset = 0;
    while (offset < THRequestBytes) {
        ssize_t count = read(STDIN_FILENO, bytes + offset, THRequestBytes - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return 0;
        offset += (size_t)count;
    }
    uint8_t extra;
    ssize_t count;
    do { count = read(STDIN_FILENO, &extra, 1); } while (count < 0 && errno == EINTR);
    return count == 0;
}
static int write_response(const THWireRequest *request, const THNativeOutcome *value) {
    uint8_t bytes[THResponseBytes];
    if (!th_wire_encode_response(request, value, bytes, sizeof(bytes))) return 0;
    size_t offset = 0;
    while (offset < sizeof(bytes)) {
        ssize_t count = write(STDOUT_FILENO, bytes + offset, sizeof(bytes) - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return 0;
        offset += (size_t)count;
    }
    return 1;
}

int main(int argc, const char *argv[]) {
    (void)argv;
    if (argc != 1) return 64;
    uint8_t request[THRequestBytes];
    THWireRequest decoded;
    if (!read_request(request) || !th_wire_decode_request(request, sizeof(request), &decoded)) return 65;
    THNativeOutcome result;
    th_native_read_once(decoded.selected_media, decoded.outer_whole,
                        decoded.block_boundary, decoded.generation, &result);
    return write_response(&decoded, &result) ? 0 : 74;
}
