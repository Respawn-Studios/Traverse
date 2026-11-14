#include "GzipDecoder.h"
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
#define TR_GZIP_HEAP_LIMIT (UINT64_C(1)<<20)
#define TR_GZIP_INPUT_CHUNK 32768u
#define TR_GZIP_OUTPUT_CHUNK 65536u

typedef union tr_block {
    max_align_t alignment;
    struct { size_t charged; } value;
} tr_block;
typedef struct tr_heap { uint64_t active,peak,allocations,limit; int refused,invalid; } tr_heap;
static voidpf tr_allocate(voidpf opaque,uInt items,uInt size) {
    tr_heap *h=opaque;
    if(size && items>SIZE_MAX/size){h->refused=1;return NULL;}
    size_t bytes=(size_t)items*size;
    if(bytes>SIZE_MAX-sizeof(tr_block) || bytes+sizeof(tr_block)>h->limit-h->active){h->refused=1;return NULL;}
    size_t charged=bytes+sizeof(tr_block);
    tr_block *block=calloc(1,charged);
    if(!block){h->refused=1;return NULL;}
    block->value.charged=charged;h->active+=charged;h->allocations++;
    if(h->active>h->peak)h->peak=h->active;
    return block+1;
}
static void tr_release(voidpf opaque,voidpf address) {
    if(!address)return;
    tr_heap *h=opaque;tr_block *block=(tr_block *)address-1;
    if(block->value.charged>h->active)h->invalid=1;
    else h->active-=block->value.charged;
    free(block);
}
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
static tr_gzip_result tr_expand_core(int input,int output,uint64_t max_input,uint64_t max_output,
    uint32_t max_members,tr_gzip_cancel cancel,void *context,tr_io io,uint64_t memory_limit) {
    tr_gzip_result result={.status=TR_GZIP_INVALID_INPUT};
    struct stat source,destination,current;z_stream stream;memset(&stream,0,sizeof(stream));
    tr_heap heap={.limit=memory_limit};int initialized=0;
    unsigned char compressed[TR_GZIP_INPUT_CHUNK],expanded[TR_GZIP_OUTPUT_CHUNK];
    if(!max_input || max_input>TR_GZIP_MAXIMUM || max_output>TR_GZIP_MAXIMUM || !max_members || max_members>128)return result;
    if(fstat(input,&source)!=0 || fstat(output,&destination)!=0 || !S_ISREG(source.st_mode) ||
       !S_ISREG(destination.st_mode) || source.st_size<0 || source.st_nlink<1 || destination.st_size!=0 ||
       destination.st_uid!=geteuid() || destination.st_nlink!=1 || (destination.st_mode&07777)!=0600 ||
       (source.st_dev==destination.st_dev && source.st_ino==destination.st_ino) ||
       (source.st_flags&SF_DATALESS)!=0 || !tr_local(input) || !tr_local(output))return result;
    int read_mode=fcntl(input,F_GETFL),write_mode=fcntl(output,F_GETFL);
    if(read_mode<0 || write_mode<0 || (read_mode&O_ACCMODE)==O_WRONLY || (write_mode&O_ACCMODE)==O_RDONLY || (write_mode&O_APPEND)!=0)return result;
    if((uint64_t)source.st_size>max_input){result.status=TR_GZIP_QUOTA;return result;}
    if(cancel && cancel(context)){result.status=TR_GZIP_CANCELLED;return result;}
    stream.zalloc=tr_allocate;stream.zfree=tr_release;stream.opaque=&heap;
    int code=inflateInit2(&stream,15+16);
    if(code!=Z_OK){result.status=code==Z_MEM_ERROR ? TR_GZIP_MEMORY_LIMIT:TR_GZIP_INTERNAL;goto finish;}
    initialized=1;
    for(;;) {
        if(cancel && cancel(context)){result.status=TR_GZIP_CANCELLED;break;}
        if(fstat(input,&current)!=0){result.status=TR_GZIP_IO;result.system_error=errno;break;}
        if(!tr_same_source(&source,&current)){result.status=TR_GZIP_SOURCE_CHANGED;break;}
        if(stream.avail_in==0 && result.read_bytes<(uint64_t)source.st_size) {
            uint64_t remaining=(uint64_t)source.st_size-result.read_bytes;
            size_t wanted=remaining<TR_GZIP_INPUT_CHUNK ? (size_t)remaining:TR_GZIP_INPUT_CHUNK;
            ssize_t count=io.read(io.context,input,compressed,wanted,(off_t)result.read_bytes);
            if(count<0 && errno==EINTR)continue;
            if(count<0){result.status=TR_GZIP_IO;result.system_error=errno;break;}
            if(count==0){result.status=TR_GZIP_TRUNCATED;break;}
            if((size_t)count>wanted){result.status=TR_GZIP_INTERNAL;break;}
            result.read_bytes+=(uint64_t)count;stream.next_in=compressed;stream.avail_in=(uInt)count;
            if(fstat(input,&current)!=0 || !tr_same_source(&source,&current)){result.status=TR_GZIP_SOURCE_CHANGED;break;}
        }
        uint64_t remaining=max_output-result.written_bytes;
        uInt capacity=remaining<TR_GZIP_OUTPUT_CHUNK ? (uInt)remaining+1:TR_GZIP_OUTPUT_CHUNK;
        stream.next_out=expanded;stream.avail_out=capacity;uInt before=stream.avail_in;
        code=inflate(&stream,Z_NO_FLUSH);
        size_t produced=capacity-stream.avail_out;uInt consumed=before-stream.avail_in;result.consumed_bytes+=consumed;
        if(code!=Z_OK && code!=Z_STREAM_END && code!=Z_BUF_ERROR) {
            result.status=code==Z_MEM_ERROR ? TR_GZIP_MEMORY_LIMIT:(code==Z_DATA_ERROR || code==Z_NEED_DICT ? TR_GZIP_CORRUPT:TR_GZIP_INTERNAL);break;
        }
        if(produced>remaining){result.status=TR_GZIP_QUOTA;break;}
        size_t offset=0;
        while(offset<produced) {
            if(cancel && cancel(context)){result.status=TR_GZIP_CANCELLED;goto finish;}
            if(fstat(input,&current)!=0 || !tr_same_source(&source,&current)){result.status=TR_GZIP_SOURCE_CHANGED;goto finish;}
            if(fstat(output,&current)!=0 || !tr_same_output(&destination,&current,result.written_bytes)){result.status=TR_GZIP_OUTPUT_CHANGED;goto finish;}
            ssize_t count=io.write(io.context,output,expanded+offset,produced-offset,(off_t)result.written_bytes);
            if(count<0 && errno==EINTR)continue;
            if(count<=0){result.status=TR_GZIP_IO;result.system_error=count<0 ? errno:EIO;goto finish;}
            if((size_t)count>produced-offset){result.status=TR_GZIP_INTERNAL;goto finish;}
            offset+=(size_t)count;result.written_bytes+=(uint64_t)count;
        }
        if(code==Z_STREAM_END) {
            result.members++;
            if(stream.avail_in==0 && result.read_bytes==(uint64_t)source.st_size){result.status=TR_GZIP_OK;break;}
            if(result.members>=max_members){result.status=TR_GZIP_QUOTA;break;}
            Bytef *next=stream.next_in;uInt available=stream.avail_in;
            if(inflateReset2(&stream,15+16)!=Z_OK){result.status=TR_GZIP_INTERNAL;break;}
            stream.next_in=next;stream.avail_in=available;
            continue;
        }
        if(!consumed && !produced) {
            if(stream.avail_in==0 && result.read_bytes<(uint64_t)source.st_size)continue;
            result.status=TR_GZIP_TRUNCATED;break;
        }
    }
finish:
    if(initialized && inflateEnd(&stream)!=Z_OK)result.status=TR_GZIP_INTERNAL;
    result.heap_peak_bytes=heap.peak;result.heap_remaining_bytes=heap.active;result.allocations=heap.allocations;
    if(heap.active || heap.invalid)result.status=TR_GZIP_INTERNAL;
    if(result.status==TR_GZIP_OK) {
        if(fsync(output)!=0){result.status=TR_GZIP_IO;result.system_error=errno;}
        else if(fstat(input,&current)!=0 || !tr_same_source(&source,&current))result.status=TR_GZIP_SOURCE_CHANGED;
        else if(fstat(output,&current)!=0 || !tr_same_output(&destination,&current,result.written_bytes))result.status=TR_GZIP_OUTPUT_CHANGED;
    }
    return result;
}
tr_gzip_result tr_gzip_expand_fd(int input,int output,uint64_t max_input,uint64_t max_output,
    uint32_t max_members,tr_gzip_cancel cancel,void *context) {
    tr_io io={.read=tr_read,.write=tr_write};
    return tr_expand_core(input,output,max_input,max_output,max_members,cancel,context,io,TR_GZIP_HEAP_LIMIT);
}
