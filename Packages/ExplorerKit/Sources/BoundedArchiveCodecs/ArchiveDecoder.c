#include "GzipDecoder.h"
#include "Bzip2Decoder.h"
#include "DecoderStreams.h"
#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

#define TR_GZIP_MAXIMUM (UINT64_C(512)<<20)
#define TR_GZIP_INPUT_CHUNK 32768u
#define TR_GZIP_OUTPUT_CHUNK 65536u

typedef struct tr_io {
    ssize_t(*read)(void *,int,void *,size_t,off_t);
    ssize_t(*write)(void *,int,const void *,size_t,off_t);
    void *context;
} tr_io;
static ssize_t tr_read(void *context,int fd,void *data,size_t size,off_t offset) {
    (void)context;return pread(fd,data,size,offset);
}
static ssize_t tr_write(void *context,int fd,const void *data,size_t size,off_t offset) {
    (void)context;return pwrite(fd,data,size,offset);
}
static int tr_same_source(const struct stat *a,const struct stat *b) {
    return a->st_dev==b->st_dev && a->st_ino==b->st_ino && a->st_mode==b->st_mode &&
        a->st_uid==b->st_uid && a->st_gid==b->st_gid && a->st_nlink==b->st_nlink &&
        a->st_size==b->st_size && a->st_flags==b->st_flags &&
        a->st_birthtimespec.tv_sec==b->st_birthtimespec.tv_sec && a->st_birthtimespec.tv_nsec==b->st_birthtimespec.tv_nsec &&
        a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec && a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec &&
        a->st_ctimespec.tv_sec==b->st_ctimespec.tv_sec && a->st_ctimespec.tv_nsec==b->st_ctimespec.tv_nsec;
}
static int tr_same_output(const struct stat *before,const struct stat *now,uint64_t written) {
    return before->st_dev==now->st_dev && before->st_ino==now->st_ino && before->st_mode==now->st_mode &&
        before->st_uid==now->st_uid && before->st_gid==now->st_gid && before->st_nlink==now->st_nlink &&
        before->st_flags==now->st_flags && now->st_size>=0 && (uint64_t)now->st_size==written &&
        before->st_birthtimespec.tv_sec==now->st_birthtimespec.tv_sec && before->st_birthtimespec.tv_nsec==now->st_birthtimespec.tv_nsec;
}
static int tr_local(int fd) {struct statfs volume;return fstatfs(fd,&volume)==0 && (volume.f_flags&MNT_LOCAL)!=0;}
static tr_codec_result tr_expand_core(enum tr_decode_kind kind,int input,int output,uint64_t max_input,uint64_t max_output,
    uint32_t max_members,tr_codec_cancel cancel,void *context,tr_io io,uint64_t memory_limit,int output_file) {
    tr_codec_result result={.status=TR_CODEC_INVALID_INPUT};
    struct stat source,destination,current;tr_decoder stream={.kind=kind};
    tr_heap heap={.limit=memory_limit};int initialized=0;
    unsigned char compressed[TR_GZIP_INPUT_CHUNK],expanded[TR_GZIP_OUTPUT_CHUNK];
    if(!max_input || max_input>TR_GZIP_MAXIMUM || max_output>TR_GZIP_MAXIMUM || !max_members || max_members>128)return result;
    if(fstat(input,&source)!=0 || !S_ISREG(source.st_mode) || source.st_size<0 || source.st_nlink<1 ||
       (source.st_flags&SF_DATALESS)!=0 || !tr_local(input))return result;
    int read_mode=fcntl(input,F_GETFL);
    if(read_mode<0 || (read_mode&O_ACCMODE)==O_WRONLY)return result;
    if(output_file) {
        if(fstat(output,&destination)!=0 || !S_ISREG(destination.st_mode) || destination.st_size!=0 ||
           destination.st_uid!=geteuid() || destination.st_nlink!=1 || (destination.st_mode&07777)!=0600 ||
           (source.st_dev==destination.st_dev && source.st_ino==destination.st_ino) || !tr_local(output))return result;
        int write_mode=fcntl(output,F_GETFL);
        if(write_mode<0 || (write_mode&O_ACCMODE)==O_RDONLY || (write_mode&O_APPEND)!=0)return result;
    }
    if((uint64_t)source.st_size>max_input){result.status=TR_CODEC_QUOTA;return result;}
    if(cancel && cancel(context)){result.status=TR_CODEC_CANCELLED;return result;}
    int code=tr_decoder_init(&stream,&heap);
    if(code!=TR_CODEC_OK){result.status=code;goto finish;}
    initialized=1;
    for(;;) {
        if(cancel && cancel(context)){result.status=TR_CODEC_CANCELLED;break;}
        if(fstat(input,&current)!=0){result.status=TR_CODEC_IO;result.system_error=errno;break;}
        if(!tr_same_source(&source,&current)){result.status=TR_CODEC_SOURCE_CHANGED;break;}
        if(stream.avail_in==0 && result.read_bytes<(uint64_t)source.st_size) {
            uint64_t remaining=(uint64_t)source.st_size-result.read_bytes;
            size_t wanted=remaining<TR_GZIP_INPUT_CHUNK ? (size_t)remaining:TR_GZIP_INPUT_CHUNK;
            ssize_t count=io.read(io.context,input,compressed,wanted,(off_t)result.read_bytes);
            if(count<0 && errno==EINTR)continue;
            if(count<0){result.status=TR_CODEC_IO;result.system_error=errno;break;}
            if(count==0){result.status=TR_CODEC_TRUNCATED;break;}
            if((size_t)count>wanted){result.status=TR_CODEC_INTERNAL;break;}
            result.read_bytes+=(uint64_t)count;stream.next_in=compressed;stream.avail_in=(uInt)count;
            if(fstat(input,&current)!=0 || !tr_same_source(&source,&current)){result.status=TR_CODEC_SOURCE_CHANGED;break;}
        }
        uint64_t remaining=max_output-result.written_bytes;
        uInt capacity=remaining<TR_GZIP_OUTPUT_CHUNK ? (uInt)remaining+1:TR_GZIP_OUTPUT_CHUNK;
        uInt before=stream.avail_in;uint32_t produced=0;int ended=0;
        code=tr_decoder_process(&stream,expanded,capacity,&produced,&ended);
        uInt consumed=before-stream.avail_in;result.consumed_bytes+=consumed;
        if(code!=TR_CODEC_OK){result.status=code;break;}
        if(produced>remaining){result.status=TR_CODEC_QUOTA;break;}
        size_t offset=0;
        while(offset<produced) {
            if(cancel && cancel(context)){result.status=TR_CODEC_CANCELLED;goto finish;}
            if(fstat(input,&current)!=0 || !tr_same_source(&source,&current)){result.status=TR_CODEC_SOURCE_CHANGED;goto finish;}
            if(output_file && (fstat(output,&current)!=0 || !tr_same_output(&destination,&current,result.written_bytes))){result.status=TR_CODEC_OUTPUT_CHANGED;goto finish;}
            ssize_t count=io.write(io.context,output,expanded+offset,produced-offset,(off_t)result.written_bytes);
            if(count<0 && errno==EINTR)continue;
            if(count<=0){result.status=TR_CODEC_IO;result.system_error=count<0 ? errno:EIO;goto finish;}
            if((size_t)count>produced-offset){result.status=TR_CODEC_INTERNAL;goto finish;}
            offset+=(size_t)count;result.written_bytes+=(uint64_t)count;
        }
        if(ended) {
            result.members++;
            if(stream.avail_in==0 && result.read_bytes==(uint64_t)source.st_size){result.status=TR_CODEC_OK;break;}
            if(result.members>=max_members){result.status=TR_CODEC_QUOTA;break;}
            initialized=0;
            if(tr_decoder_end(&stream)!=TR_CODEC_OK){result.status=TR_CODEC_INTERNAL;break;}
            code=tr_decoder_init(&stream,&heap);
            if(code!=TR_CODEC_OK){result.status=code;break;}
            initialized=1;
            continue;
        }
        if(!consumed && !produced) {
            if(stream.avail_in==0 && result.read_bytes<(uint64_t)source.st_size)continue;
            result.status=TR_CODEC_TRUNCATED;break;
        }
    }
finish:
    if(initialized && tr_decoder_end(&stream)!=TR_CODEC_OK)result.status=TR_CODEC_INTERNAL;
    result.heap_peak_bytes=heap.peak;result.heap_remaining_bytes=heap.active;result.allocations=heap.allocations;
    if(heap.active || heap.invalid)result.status=TR_CODEC_INTERNAL;
    if(result.status==TR_CODEC_OK) {
        if(output_file && fsync(output)!=0){result.status=TR_CODEC_IO;result.system_error=errno;}
        else if(fstat(input,&current)!=0 || !tr_same_source(&source,&current))result.status=TR_CODEC_SOURCE_CHANGED;
        else if(output_file && (fstat(output,&current)!=0 || !tr_same_output(&destination,&current,result.written_bytes)))result.status=TR_CODEC_OUTPUT_CHANGED;
    }
    return result;
}
tr_codec_result tr_gzip_expand_fd(int input,int output,uint64_t max_input,uint64_t max_output,
    uint32_t max_members,tr_codec_cancel cancel,void *context) {
    tr_io io={.read=tr_read,.write=tr_write};
    return tr_expand_core(TR_DECODE_GZIP,input,output,max_input,max_output,max_members,cancel,context,io,TR_GZIP_HEAP_LIMIT,1);
}

typedef struct tr_consumer { tr_codec_consume callback; void *context; } tr_consumer;
static ssize_t tr_consume(void *context,int fd,const void *data,size_t size,off_t offset) {
    (void)fd;(void)offset;tr_consumer *consumer=context;
    if(size>TR_GZIP_OUTPUT_CHUNK || !consumer->callback(consumer->context,data,(uint32_t)size)){errno=EIO;return -1;}
    return (ssize_t)size;
}
tr_codec_result tr_gzip_consume_fd(int input,uint64_t max_input,uint64_t max_output,
    uint32_t max_members,tr_codec_cancel cancel,tr_codec_consume consume,void *context) {
    if(!consume){tr_codec_result invalid={.status=TR_CODEC_INVALID_INPUT};return invalid;}
    tr_consumer consumer={.callback=consume,.context=context};
    tr_io io={.read=tr_read,.write=tr_consume,.context=&consumer};
    return tr_expand_core(TR_DECODE_GZIP,input,-1,max_input,max_output,max_members,cancel,context,io,TR_GZIP_HEAP_LIMIT,0);
}

tr_codec_result tr_bzip2_expand_fd(int input,int output,uint64_t max_input,uint64_t max_output,
    uint32_t max_members,tr_codec_cancel cancel,void *context) {
    tr_io io={.read=tr_read,.write=tr_write};
    return tr_expand_core(TR_DECODE_BZIP2,input,output,max_input,max_output,max_members,cancel,context,io,UINT64_C(4)<<20,1);
}
tr_codec_result tr_bzip2_consume_fd(int input,uint64_t max_input,uint64_t max_output,
    uint32_t max_members,tr_codec_cancel cancel,tr_codec_consume consume,void *context) {
    if(!consume){tr_codec_result invalid={.status=TR_CODEC_INVALID_INPUT};return invalid;}
    tr_consumer consumer={.callback=consume,.context=context};
    tr_io io={.read=tr_read,.write=tr_consume,.context=&consumer};
    return tr_expand_core(TR_DECODE_BZIP2,input,-1,max_input,max_output,max_members,cancel,context,io,UINT64_C(4)<<20,0);
}
