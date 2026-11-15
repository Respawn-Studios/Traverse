#ifndef TRAVERSE_BZIP2_DECODER_H
#define TRAVERSE_BZIP2_DECODER_H
#include "ArchiveCodec.h"
/* Same descriptor admission, complete-stream, quota and ownership rules as the
 * gzip path. Normal decoding uses at most 4 MiB of charged codec allocations. */
tr_codec_result tr_bzip2_expand_fd(int input_fd,int output_fd,
    uint64_t maximum_input_bytes,uint64_t maximum_output_bytes,
    uint32_t maximum_members,tr_codec_cancel cancel,void *context);
tr_codec_result tr_bzip2_consume_fd(int input_fd,
    uint64_t maximum_input_bytes,uint64_t maximum_output_bytes,
    uint32_t maximum_members,tr_codec_cancel cancel,tr_codec_consume consume,void *context);
#endif
