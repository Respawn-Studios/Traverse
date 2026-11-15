#ifndef TRAVERSE_CODEC_MEMORY_H
#define TRAVERSE_CODEC_MEMORY_H
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <zlib.h>

#define TR_GZIP_HEAP_LIMIT (UINT64_C(1)<<20)
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
static void *tr_bz_allocate(void *opaque,int items,int size) {
    if(items<=0 || size<=0){((tr_heap *)opaque)->refused=1;return NULL;}
    return tr_allocate(opaque,(uInt)items,(uInt)size);
}
#endif
