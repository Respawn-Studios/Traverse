#include "Bzip2Encoder.h"
#include "CodecMemory.h"
#include <bzlib.h>
#include <errno.h>
#include <string.h>

#define TR_BZIP2_MAXIMUM (UINT64_C(512)<<20)
#define TR_BZIP2_CHUNK 65536u
struct tr_bzip2_encoder {
    bz_stream stream;
    tr_heap heap;
    tr_codec_result result;
    uint64_t maximum_input,maximum_output;
    tr_codec_cancel cancel;
    tr_codec_consume consume;
    void *context;
    int initialized,finished,busy;
};
static tr_codec_result tr_result(tr_bzip2_encoder *e) {
    e->result.heap_peak_bytes=e->heap.peak;e->result.heap_remaining_bytes=e->heap.active;
    e->result.allocations=e->heap.allocations;return e->result;
}
static void tr_end(tr_bzip2_encoder *e) {
    if(e->initialized) {
        int status=BZ2_bzCompressEnd(&e->stream);e->initialized=0;
        if(status!=BZ_OK && e->result.status==TR_CODEC_OK)e->result.status=TR_CODEC_INTERNAL;
    }
    if(e->heap.active || e->heap.invalid)e->result.status=TR_CODEC_INTERNAL;
}
tr_bzip2_encoder *tr_bzip2_encoder_create(uint64_t max_input,uint64_t max_output,int32_t block_size,
    tr_codec_cancel cancel,tr_codec_consume consume,void *context,tr_codec_result *result) {
    if(!result)return NULL;
    memset(result,0,sizeof(*result));result->status=TR_CODEC_INVALID_INPUT;
    if(!max_input || max_input>TR_BZIP2_MAXIMUM || !max_output || max_output>TR_BZIP2_MAXIMUM ||
       block_size<1 || block_size>9 || !consume)return NULL;
    if(cancel && cancel(context)){result->status=TR_CODEC_CANCELLED;return NULL;}
    tr_bzip2_encoder *e=calloc(1,sizeof(*e));
    if(!e){result->status=TR_CODEC_MEMORY_LIMIT;return NULL;}
    e->maximum_input=max_input;e->maximum_output=max_output;e->cancel=cancel;e->consume=consume;e->context=context;
    e->heap.limit=UINT64_C(8)<<20;
    e->stream.bzalloc=tr_bz_allocate;e->stream.bzfree=tr_release;e->stream.opaque=&e->heap;
    int status=BZ2_bzCompressInit(&e->stream,block_size,0,30);
    if(status!=BZ_OK) {
        e->result.status=status==BZ_MEM_ERROR ? TR_CODEC_MEMORY_LIMIT:TR_CODEC_INTERNAL;
        if(e->stream.state)e->initialized=1;
        tr_end(e);*result=tr_result(e);free(e);return NULL;
    }
    e->initialized=1;*result=tr_result(e);return e;
}
static tr_codec_result tr_encode(tr_bzip2_encoder *e,const uint8_t *bytes,uint32_t count,int finish) {
    tr_codec_result invalid={.status=TR_CODEC_INVALID_INPUT};
    if(!e || e->busy || e->finished)return invalid;
    if(e->result.status!=TR_CODEC_OK)return tr_result(e);
    if(!e->initialized || count>TR_BZIP2_CHUNK || (count && !bytes))return invalid;
    if(count>e->maximum_input-e->result.read_bytes){e->result.status=TR_CODEC_QUOTA;return tr_result(e);}
    e->busy=1;e->result.read_bytes+=count;e->stream.next_in=(char *)bytes;e->stream.avail_in=count;
    uint8_t output[TR_BZIP2_CHUNK];
    do {
        if(e->cancel && e->cancel(e->context)){e->result.status=TR_CODEC_CANCELLED;break;}
        unsigned int before=e->stream.avail_in;
        e->stream.next_out=(char *)output;e->stream.avail_out=TR_BZIP2_CHUNK;
        int status=BZ2_bzCompress(&e->stream,finish ? BZ_FINISH:BZ_RUN);
        uint32_t produced=TR_BZIP2_CHUNK-e->stream.avail_out;
        e->result.consumed_bytes+=before-e->stream.avail_in;
        if((!finish && status!=BZ_RUN_OK) || (finish && status!=BZ_FINISH_OK && status!=BZ_STREAM_END)) {
            e->result.status=status==BZ_MEM_ERROR ? TR_CODEC_MEMORY_LIMIT:TR_CODEC_INTERNAL;break;
        }
        if(produced>e->maximum_output-e->result.written_bytes){e->result.status=TR_CODEC_QUOTA;break;}
        if(produced) {
            if(!e->consume(e->context,output,produced)){e->result.status=TR_CODEC_IO;e->result.system_error=EIO;break;}
            e->result.written_bytes+=produced;
        }
        if(status==BZ_STREAM_END) {
            uint64_t consumed=((uint64_t)e->stream.total_in_hi32<<32)|e->stream.total_in_lo32;
            uint64_t written=((uint64_t)e->stream.total_out_hi32<<32)|e->stream.total_out_lo32;
            if(!finish || e->stream.avail_in || consumed!=e->result.consumed_bytes || written!=e->result.written_bytes) {
                e->result.status=TR_CODEC_INTERNAL;break;
            }
            e->finished=1;e->result.members=1;break;
        }
        if(!produced && before==e->stream.avail_in){e->result.status=TR_CODEC_INTERNAL;break;}
    } while(finish || e->stream.avail_in);
    e->stream.next_in=NULL;e->stream.next_out=NULL;e->busy=0;
    if(finish)tr_end(e);
    return tr_result(e);
}
tr_codec_result tr_bzip2_encoder_write(tr_bzip2_encoder *e,const uint8_t *bytes,uint32_t count) {
    if(!count && e && !e->finished && !e->busy)return tr_result(e);
    return tr_encode(e,bytes,count,0);
}
tr_codec_result tr_bzip2_encoder_finish(tr_bzip2_encoder *e) {return tr_encode(e,NULL,0,1);}
tr_codec_result tr_bzip2_encoder_destroy(tr_bzip2_encoder *e) {
    tr_codec_result invalid={.status=TR_CODEC_INVALID_INPUT};if(!e)return invalid;
    if(e->result.status==TR_CODEC_OK && !e->finished)e->result.status=TR_CODEC_CANCELLED;
    tr_end(e);tr_codec_result result=tr_result(e);free(e);return result;
}
