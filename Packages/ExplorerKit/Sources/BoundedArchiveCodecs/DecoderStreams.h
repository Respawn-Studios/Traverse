#ifndef TRAVERSE_DECODER_STREAMS_H
#define TRAVERSE_DECODER_STREAMS_H
#include "ArchiveCodec.h"
#include "CodecMemory.h"
#include <bzlib.h>
#include <string.h>

/* Two concrete codecs share the descriptor admission/I/O loop. No codec owns
 * a path, output descriptor, thread, or publication authority. */
enum tr_decode_kind { TR_DECODE_GZIP, TR_DECODE_BZIP2 };
typedef struct tr_decoder {
    enum tr_decode_kind kind;
    union { z_stream gzip; bz_stream bzip2; } state;
    uint8_t *next_in;
    uint32_t avail_in;
} tr_decoder;
static int tr_decoder_init(tr_decoder *s,tr_heap *heap) {
    memset(&s->state,0,sizeof(s->state));
    if(s->kind==TR_DECODE_GZIP) {
        z_stream *z=&s->state.gzip;
        z->zalloc=tr_allocate;z->zfree=tr_release;z->opaque=heap;
        int code=inflateInit2(z,15+16);
        if(code==Z_OK)return TR_CODEC_OK;
        if(z->state)inflateEnd(z);
        return code==Z_MEM_ERROR ? TR_CODEC_MEMORY_LIMIT:TR_CODEC_INTERNAL;
    }
    bz_stream *b=&s->state.bzip2;
    b->bzalloc=tr_bz_allocate;b->bzfree=tr_release;b->opaque=heap;
    int code=BZ2_bzDecompressInit(b,0,0);
    if(code==BZ_OK)return TR_CODEC_OK;
    if(b->state)BZ2_bzDecompressEnd(b);
    return code==BZ_MEM_ERROR ? TR_CODEC_MEMORY_LIMIT:TR_CODEC_INTERNAL;
}
static int tr_decoder_end(tr_decoder *s) {
    return s->kind==TR_DECODE_GZIP
        ? (inflateEnd(&s->state.gzip)==Z_OK ? TR_CODEC_OK:TR_CODEC_INTERNAL)
        : (BZ2_bzDecompressEnd(&s->state.bzip2)==BZ_OK ? TR_CODEC_OK:TR_CODEC_INTERNAL);
}
static int tr_decoder_process(tr_decoder *s,uint8_t *output,uint32_t capacity,uint32_t *produced,int *ended) {
    int code;
    if(s->kind==TR_DECODE_GZIP) {
        z_stream *z=&s->state.gzip;
        z->next_in=s->next_in;z->avail_in=s->avail_in;z->next_out=output;z->avail_out=capacity;
        code=inflate(z,Z_NO_FLUSH);
        s->next_in=z->next_in;s->avail_in=z->avail_in;*produced=capacity-z->avail_out;*ended=code==Z_STREAM_END;
        if(code==Z_OK || code==Z_STREAM_END || code==Z_BUF_ERROR)return TR_CODEC_OK;
        return code==Z_MEM_ERROR ? TR_CODEC_MEMORY_LIMIT:(code==Z_DATA_ERROR || code==Z_NEED_DICT ? TR_CODEC_CORRUPT:TR_CODEC_INTERNAL);
    }
    bz_stream *b=&s->state.bzip2;
    b->next_in=(char *)s->next_in;b->avail_in=s->avail_in;b->next_out=(char *)output;b->avail_out=capacity;
    code=BZ2_bzDecompress(b);
    s->next_in=(uint8_t *)b->next_in;s->avail_in=b->avail_in;*produced=capacity-b->avail_out;*ended=code==BZ_STREAM_END;
    if(code==BZ_OK || code==BZ_STREAM_END)return TR_CODEC_OK;
    return code==BZ_MEM_ERROR ? TR_CODEC_MEMORY_LIMIT:(code==BZ_DATA_ERROR || code==BZ_DATA_ERROR_MAGIC ? TR_CODEC_CORRUPT:TR_CODEC_INTERNAL);
}
#endif
