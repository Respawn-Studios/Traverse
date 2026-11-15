#ifndef TRAVERSE_GZIP_ENCODER_H
#define TRAVERSE_GZIP_ENCODER_H
#include "GzipDecoder.h"
typedef struct tr_gzip_encoder tr_gzip_encoder;
typedef struct tr_gzip_header {
    uint32_t modification_time;
    uint8_t operating_system;
    uint8_t text;
    uint8_t has_extra,has_name,has_comment,header_crc;
    const uint8_t *extra,*name,*comment;
    uint32_t extra_count,name_count,comment_count;
} tr_gzip_header;
/* One serial caller owns this bounded codec. It owns no descriptor or path;
 * admitted output goes to the synchronous consumer. Chunks are <=64 KiB.
 * Finish writes the gzip trailer and releases zlib allocations. Destroy is
 * always required, including after failure; it never closes caller resources.
 * Header buffers are copied during create into charged encoder-owned storage.
 * A complete header is capped at 64 KiB; absent and empty fields are distinct. */
tr_gzip_encoder *tr_gzip_encoder_create(uint64_t maximum_input_bytes,
    uint64_t maximum_output_bytes,int32_t level,const tr_gzip_header *header,tr_codec_cancel cancel,
    tr_codec_consume consume,void *context,tr_codec_result *result);
tr_codec_result tr_gzip_encoder_write(tr_gzip_encoder *encoder,const uint8_t *bytes,uint32_t count);
tr_codec_result tr_gzip_encoder_finish(tr_gzip_encoder *encoder);
tr_codec_result tr_gzip_encoder_destroy(tr_gzip_encoder *encoder);
#endif
