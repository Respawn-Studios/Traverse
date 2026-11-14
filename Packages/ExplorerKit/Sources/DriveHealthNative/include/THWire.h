#ifndef TRAVERSE_HEALTH_WIRE_H
#define TRAVERSE_HEALTH_WIRE_H

#include "THAcquisition.h"
#include <stddef.h>
#include <stdint.h>

enum { THRequestBytes = 64, THResponseBytes = 256 };
typedef struct {
    uint8_t nonce[16];
    uint64_t selected_media, outer_whole, block_boundary, generation;
} THWireRequest;

/* Pure fixed-format conversion only: no acquisition, I/O or allocation.
 * Decode rejects anything except the existing exact THR2 contract and clears
 * its output on failure. Encode preserves the worker's THS2 byte layout. */
int th_wire_decode_request(const uint8_t *bytes, size_t count, THWireRequest *out);
int th_wire_encode_response(const THWireRequest *request, const THNativeOutcome *result,
                            uint8_t *bytes, size_t count);

#endif
