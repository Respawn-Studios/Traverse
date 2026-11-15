#include "GzipEncoder.h"
#include "GzipMemory.h"
#include <errno.h>
#include <string.h>

#define TR_GZIP_MAXIMUM (UINT64_C(512)<<20)
#define TR_GZIP_CHUNK 65536u
struct tr_gzip_encoder {
    z_stream stream;
    tr_heap heap;
    tr_gzip_result result;
    uint64_t maximum_input,maximum_output;
    tr_gzip_cancel cancel;
    tr_gzip_consume consume;
    void *context;
    int initialized,finished,busy;
};
static tr_gzip_result tr_result(tr_gzip_encoder *encoder) {
    encoder->result.heap_peak_bytes=encoder->heap.peak;
    encoder->result.heap_remaining_bytes=encoder->heap.active;
    encoder->result.allocations=encoder->heap.allocations;
    return encoder->result;
}
static void tr_end(tr_gzip_encoder *encoder) {
    if(encoder->initialized) {
        int status=deflateEnd(&encoder->stream);encoder->initialized=0;
        if(status!=Z_OK && encoder->result.status==TR_GZIP_OK)encoder->result.status=TR_GZIP_INTERNAL;
    }
    if(encoder->heap.active || encoder->heap.invalid)encoder->result.status=TR_GZIP_INTERNAL;
}
tr_gzip_encoder *tr_gzip_encoder_create(uint64_t max_input,uint64_t max_output,int32_t level,
    tr_gzip_cancel cancel,tr_gzip_consume consume,void *context,tr_gzip_result *result) {
    if(!result)return NULL;
    memset(result,0,sizeof(*result));result->status=TR_GZIP_INVALID_INPUT;
    if(!max_input || max_input>TR_GZIP_MAXIMUM || !max_output || max_output>TR_GZIP_MAXIMUM ||
       level<0 || level>9 || !consume)return NULL;
    if(cancel && cancel(context)){result->status=TR_GZIP_CANCELLED;return NULL;}
    tr_gzip_encoder *encoder=calloc(1,sizeof(*encoder));
    if(!encoder){result->status=TR_GZIP_MEMORY_LIMIT;return NULL;}
    encoder->maximum_input=max_input;encoder->maximum_output=max_output;
    encoder->cancel=cancel;encoder->consume=consume;encoder->context=context;
    encoder->heap.limit=TR_GZIP_HEAP_LIMIT;
    encoder->stream.zalloc=tr_allocate;encoder->stream.zfree=tr_release;encoder->stream.opaque=&encoder->heap;
    int status=deflateInit2(&encoder->stream,level,Z_DEFLATED,15+16,8,Z_DEFAULT_STRATEGY);
    if(status!=Z_OK) {
        encoder->result.status=status==Z_MEM_ERROR ? TR_GZIP_MEMORY_LIMIT:TR_GZIP_INTERNAL;
        if(encoder->stream.state) {encoder->initialized=1;tr_end(encoder);}
        *result=tr_result(encoder);free(encoder);return NULL;
    }
    encoder->initialized=1;*result=tr_result(encoder);return encoder;
}
static tr_gzip_result tr_encode(tr_gzip_encoder *encoder,const uint8_t *bytes,uint32_t count,int finish) {
    tr_gzip_result invalid={.status=TR_GZIP_INVALID_INPUT};
    if(!encoder || encoder->busy || encoder->finished)return invalid;
    if(encoder->result.status!=TR_GZIP_OK)return tr_result(encoder);
    if(!encoder->initialized || count>TR_GZIP_CHUNK || (count && !bytes))return invalid;
    if(count>encoder->maximum_input-encoder->result.read_bytes){encoder->result.status=TR_GZIP_QUOTA;return tr_result(encoder);}
    encoder->busy=1;encoder->result.read_bytes+=count;
    encoder->stream.next_in=(Bytef *)bytes;encoder->stream.avail_in=count;
    uint8_t output[TR_GZIP_CHUNK];
    do {
        if(encoder->cancel && encoder->cancel(encoder->context)){encoder->result.status=TR_GZIP_CANCELLED;break;}
        uInt before=encoder->stream.avail_in;
        encoder->stream.next_out=output;encoder->stream.avail_out=TR_GZIP_CHUNK;
        int status=deflate(&encoder->stream,finish ? Z_FINISH:Z_NO_FLUSH);
        uint32_t produced=TR_GZIP_CHUNK-encoder->stream.avail_out;
        encoder->result.consumed_bytes+=before-encoder->stream.avail_in;
        if(status!=Z_OK && status!=Z_STREAM_END){encoder->result.status=status==Z_MEM_ERROR ? TR_GZIP_MEMORY_LIMIT:TR_GZIP_INTERNAL;break;}
        if(produced>encoder->maximum_output-encoder->result.written_bytes){encoder->result.status=TR_GZIP_QUOTA;break;}
        if(produced) {
            if(!encoder->consume(encoder->context,output,produced)){encoder->result.status=TR_GZIP_IO;encoder->result.system_error=EIO;break;}
            encoder->result.written_bytes+=produced;
        }
        if(status==Z_STREAM_END) {
            if(!finish || encoder->stream.avail_in){encoder->result.status=TR_GZIP_INTERNAL;break;}
            encoder->finished=1;encoder->result.members=1;break;
        }
        if(!produced && before==encoder->stream.avail_in){encoder->result.status=TR_GZIP_INTERNAL;break;}
    } while(finish || encoder->stream.avail_in);
    encoder->stream.next_in=NULL;encoder->stream.next_out=NULL;encoder->busy=0;
    if(finish)tr_end(encoder);
    return tr_result(encoder);
}
tr_gzip_result tr_gzip_encoder_write(tr_gzip_encoder *encoder,const uint8_t *bytes,uint32_t count) {
    if(count==0 && encoder && !encoder->finished && !encoder->busy)return tr_result(encoder);
    return tr_encode(encoder,bytes,count,0);
}
tr_gzip_result tr_gzip_encoder_finish(tr_gzip_encoder *encoder) { return tr_encode(encoder,NULL,0,1); }
tr_gzip_result tr_gzip_encoder_destroy(tr_gzip_encoder *encoder) {
    tr_gzip_result invalid={.status=TR_GZIP_INVALID_INPUT};if(!encoder)return invalid;
    if(encoder->result.status==TR_GZIP_OK && !encoder->finished)encoder->result.status=TR_GZIP_CANCELLED;
    tr_end(encoder);tr_gzip_result result=tr_result(encoder);free(encoder);return result;
}
