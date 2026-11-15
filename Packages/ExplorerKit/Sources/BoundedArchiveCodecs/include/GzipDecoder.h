#ifndef TRAVERSE_GZIP_DECODER_H
#define TRAVERSE_GZIP_DECODER_H
#include "ArchiveCodec.h"
/* Caller supplies already-admitted descriptors, private output ownership and a
 * cancellation context retained until synchronous return. No path/publication. */
tr_codec_result tr_gzip_expand_fd(int input_fd, int output_fd,
    uint64_t maximum_input_bytes, uint64_t maximum_output_bytes,
    uint32_t maximum_members, tr_codec_cancel cancel, void *context);
/* Read-only verification without a decoded output file. Source descriptor,
 * codec heap, input/output quotas and complete-member rules are unchanged. */
tr_codec_result tr_gzip_consume_fd(int input_fd,
    uint64_t maximum_input_bytes,uint64_t maximum_output_bytes,
    uint32_t maximum_members,tr_codec_cancel cancel,tr_codec_consume consume,void *context);
#endif
