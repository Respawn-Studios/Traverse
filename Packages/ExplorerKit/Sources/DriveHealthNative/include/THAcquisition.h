#ifndef TRAVERSE_HEALTH_ACQUISITION_H
#define TRAVERSE_HEALTH_ACQUISITION_H

#include "THSMART.h"
#include <stdint.h>

enum {
    THNativeSample = 0,
    THNativeInvalid = 1,
    THNativeUnsupported = 2,
    THNativeChanged = 3,
    THNativeUnavailable = 4,
    THNativeReadFailure = 5,
    THNativeUncertain = 6
};

/* Values only. This function is called by the one-shot helper, never by the app.
 * Registry IDs identify the one selected attachment only until reboot. */
typedef struct {
    uint32_t status;
    THSMARTResult smart;
    uint64_t provider;
    int64_t captured_seconds;
    int32_t captured_nanoseconds;
    uint8_t cleanup_confirmed;
} THNativeOutcome;

/* Pure classification of this block device's own protocol dictionary.
 * 0: unsupported, 1: ATA/SATA, 2: native NVMe. This grants no I/O authority. */
uint8_t th_native_transport(CFTypeRef characteristics);

void th_native_read_once(uint64_t selected_media, uint64_t outer_whole,
                         uint64_t block_boundary, uint64_t generation,
                         THNativeOutcome *out);

#endif
