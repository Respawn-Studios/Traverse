#ifndef TRAVERSE_ARCHIVE_CODEC_H
#define TRAVERSE_ARCHIVE_CODEC_H
#include <stdint.h>
typedef int (*tr_codec_cancel)(void *context);
/* Consume at most 64 KiB synchronously; nonzero accepts the complete chunk.
 * The decoder retains no pointer after this callback returns. */
typedef int (*tr_codec_consume)(void *context,const uint8_t *bytes,uint32_t count);
enum tr_codec_status {
    TR_CODEC_OK=0, TR_CODEC_INVALID_INPUT=1, TR_CODEC_CORRUPT=2,
    TR_CODEC_TRUNCATED=3, TR_CODEC_QUOTA=4, TR_CODEC_CANCELLED=5,
    TR_CODEC_IO=6, TR_CODEC_SOURCE_CHANGED=7, TR_CODEC_OUTPUT_CHANGED=8,
    TR_CODEC_MEMORY_LIMIT=9, TR_CODEC_INTERNAL=10
};
typedef struct tr_codec_result {
    int32_t status, system_error;
    uint64_t read_bytes, consumed_bytes, written_bytes, members;
    uint64_t heap_peak_bytes, heap_remaining_bytes, allocations;
} tr_codec_result;
#endif
