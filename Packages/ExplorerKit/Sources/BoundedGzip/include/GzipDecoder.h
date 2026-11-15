#ifndef TRAVERSE_GZIP_DECODER_H
#define TRAVERSE_GZIP_DECODER_H
#include <stdint.h>
typedef int (*tr_gzip_cancel)(void *context);
/* Consume at most 64 KiB synchronously; nonzero accepts the complete chunk.
 * The decoder retains no pointer after this callback returns. */
typedef int (*tr_gzip_consume)(void *context,const uint8_t *bytes,uint32_t count);
enum tr_gzip_status {
    TR_GZIP_OK=0, TR_GZIP_INVALID_INPUT=1, TR_GZIP_CORRUPT=2,
    TR_GZIP_TRUNCATED=3, TR_GZIP_QUOTA=4, TR_GZIP_CANCELLED=5,
    TR_GZIP_IO=6, TR_GZIP_SOURCE_CHANGED=7, TR_GZIP_OUTPUT_CHANGED=8,
    TR_GZIP_MEMORY_LIMIT=9, TR_GZIP_INTERNAL=10
};
typedef struct tr_gzip_result {
    int32_t status, system_error;
    uint64_t read_bytes, consumed_bytes, written_bytes, members;
    uint64_t heap_peak_bytes, heap_remaining_bytes, allocations;
} tr_gzip_result;
/* Caller supplies already-admitted descriptors, private output ownership and a
 * cancellation context retained until synchronous return. No path/publication. */
tr_gzip_result tr_gzip_expand_fd(int input_fd, int output_fd,
    uint64_t maximum_input_bytes, uint64_t maximum_output_bytes,
    uint32_t maximum_members, tr_gzip_cancel cancel, void *context);
/* Read-only verification without a decoded output file. Source descriptor,
 * codec heap, input/output quotas and complete-member rules are unchanged. */
tr_gzip_result tr_gzip_consume_fd(int input_fd,
    uint64_t maximum_input_bytes,uint64_t maximum_output_bytes,
    uint32_t maximum_members,tr_gzip_cancel cancel,tr_gzip_consume consume,void *context);
#endif
