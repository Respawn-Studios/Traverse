#ifndef TRAVERSE_BZIP2_ENCODER_H
#define TRAVERSE_BZIP2_ENCODER_H
#include "ArchiveCodec.h"
typedef struct tr_bzip2_encoder tr_bzip2_encoder;
/* Serial synchronous owner; no descriptor/path authority. Write chunks are at
 * most 64 KiB. The block size is 1...9 (100 KiB units); charged heap <=8 MiB.
 * Cancellation is polled around library calls; one block's sort can complete
 * inside a call before a stop is observed. Destroy is always required. */
tr_bzip2_encoder *tr_bzip2_encoder_create(uint64_t maximum_input_bytes,
    uint64_t maximum_output_bytes,int32_t block_size,tr_codec_cancel cancel,
    tr_codec_consume consume,void *context,tr_codec_result *result);
tr_codec_result tr_bzip2_encoder_write(tr_bzip2_encoder *encoder,const uint8_t *bytes,uint32_t count);
tr_codec_result tr_bzip2_encoder_finish(tr_bzip2_encoder *encoder);
tr_codec_result tr_bzip2_encoder_destroy(tr_bzip2_encoder *encoder);
#endif
