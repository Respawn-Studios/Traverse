#include "THAssociation.h"
#include <CommonCrypto/CommonDigest.h>
#include <IOKit/storage/ata/ATASMARTLib.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>
#include <string.h>

_Static_assert(CC_SHA256_DIGEST_LENGTH==32,"Association seal size changed");
_Static_assert(sizeof(CFUUIDBytes)==16,"SDK UUID value size changed");
_Static_assert(64*(3*8+4+64)+6*8<=8192,"Bounded association buffer changed");
static uint8_t capability(CFTypeRef value) {
    if(!value)return THACapAbsent;
    if(CFGetTypeID(value)!=CFBooleanGetTypeID())return THACapMalformed;
    return CFBooleanGetValue((CFBooleanRef)value)?THACapTrue:THACapFalse;
}
static int uuid_equal(CFUUIDBytes a,CFUUIDBytes b){return memcmp(&a,&b,sizeof(a))==0;}
static int mapping(CFTypeRef value,CFUUIDBytes key,uint8_t digest[32]) {
    if(!value || CFGetTypeID(value)!=CFStringGetTypeID())return 0;
    CFIndex count=CFStringGetLength((CFStringRef)value);
    if(count<1 || count>1024)return 0;
    UniChar characters[1024];CFStringGetCharacters((CFStringRef)value,CFRangeMake(0,count),characters);
    for(CFIndex i=0;i<count;i++)if(characters[i]==0)return 0;
    char bytes[4097];
    if(!CFStringGetCString((CFStringRef)value,bytes,sizeof(bytes),kCFStringEncodingUTF8))return 0;
    unsigned char sealed[sizeof(key)+sizeof(bytes)];size_t length=strlen(bytes);
    memcpy(sealed,&key,sizeof(key));memcpy(sealed+sizeof(key),bytes,length);
    return CC_SHA256(sealed,(CC_LONG)(sizeof(key)+length),digest)!=NULL;
}
THAProperties tha_parse_properties(CFTypeRef ata,CFTypeRef nvme,CFTypeRef plugins) {
    THAProperties out={0};out.ata_capability=capability(ata);out.nvme_capability=capability(nvme);
    if(!plugins)return out;
    if(CFGetTypeID(plugins)!=CFDictionaryGetTypeID()){out.ata_route=out.nvme_route=THARouteMalformed;return out;}
    CFIndex count=CFDictionaryGetCount((CFDictionaryRef)plugins);
    if(count<0 || count>64){out.ata_route=out.nvme_route=THARouteMalformed;return out;}
    const void *keys[64],*values[64];CFUUIDBytes seen[64];size_t used=0;
    CFDictionaryGetKeysAndValues((CFDictionaryRef)plugins,keys,values);
    CFUUIDBytes ata_key=CFUUIDGetUUIDBytes(kIOATASMARTUserClientTypeID),nvme_key=CFUUIDGetUUIDBytes(kIONVMeSMARTUserClientTypeID);
    for(CFIndex i=0;i<count;i++) {
        if(!keys[i] || CFGetTypeID(keys[i])!=CFStringGetTypeID() || CFStringGetLength(keys[i])!=36)goto malformed;
        CFUUIDRef key=CFUUIDCreateFromString(kCFAllocatorDefault,(CFStringRef)keys[i]);
        if(!key)goto malformed;
        CFUUIDBytes bytes=CFUUIDGetUUIDBytes(key);CFRelease(key);
        for(size_t j=0;j<used;j++)if(uuid_equal(seen[j],bytes))goto malformed;
        seen[used++]=bytes;
        if(uuid_equal(bytes,ata_key)) {
            if(!mapping(values[i],bytes,out.ata_mapping))goto malformed;
            out.ata_route=THARouteAdvertised;
        } else if(uuid_equal(bytes,nvme_key)) {
            if(!mapping(values[i],bytes,out.nvme_mapping))goto malformed;
            out.nvme_route=THARouteAdvertised;
        }
    }
    return out;
malformed:
    out.ata_route=out.nvme_route=THARouteMalformed;memset(out.ata_mapping,0,32);memset(out.nvme_mapping,0,32);return out;
}
static void number(unsigned char *data,size_t *used,uint64_t value) {
    for(unsigned i=0;i<8;i++)data[(*used)++]=(unsigned char)(value>>(56-8*i));
}
static int digest_present(const uint8_t *value){uint8_t all=0;for(size_t i=0;i<32;i++)all|=value[i];return all!=0;}
THAAssociation tha_associate(const THANode *nodes,size_t count,THABinding binding) {
    THAAssociation out={.status=THAInvalid};
    if(!nodes || !count || count>64 || !binding.selected_media || !binding.whole_media || !binding.block_boundary || !binding.endpoint || !binding.generation)return out;
    if(binding.scope!=THAPhysical){out.status=THAUnsupported;return out;}
    for(size_t i=0;i<count;i++) {
        if(!nodes[i].registry_id || nodes[i].parent_count>1)return out;
        for(size_t j=0;j<i;j++)if(nodes[i].registry_id==nodes[j].registry_id)return out;
    }
    size_t order[64],length=0,whole=SIZE_MAX,block=SIZE_MAX;uint64_t current=binding.selected_media;
    for(;;) {
        size_t found=count;
        for(size_t i=0;i<count;i++)if(nodes[i].registry_id==current){found=i;break;}
        if(found==count || length==count)return out;
        for(size_t i=0;i<length;i++)if(order[i]==found)return out;
        order[length]=found;
        if(current==binding.whole_media)whole=length;
        if(current==binding.block_boundary)block=length;
        length++;
        if(current==binding.endpoint)break;
        if(nodes[found].parent_count!=1 || !nodes[found].parent_id)return out;
        current=nodes[found].parent_id;
    }
    if(length!=count || whole==SIZE_MAX || block==SIZE_MAX || whole>=block)return out;
    if(nodes[order[length-1]].parent_count==1) {
        for(size_t i=0;i<length;i++)if(nodes[order[length-1]].parent_id==nodes[order[i]].registry_id)return out;
    }
    unsigned char bytes[8192];size_t used=0;unsigned candidates=0;
    number(bytes,&used,binding.selected_media);number(bytes,&used,binding.whole_media);number(bytes,&used,binding.block_boundary);
    number(bytes,&used,binding.endpoint);number(bytes,&used,binding.generation);number(bytes,&used,binding.scope);
    for(size_t i=0;i<length;i++) {
        const THANode *node=&nodes[order[i]];const THAProperties *p=&node->properties;
        if(p->ata_capability>THACapMalformed || p->nvme_capability>THACapMalformed || p->ata_route>THARouteMalformed || p->nvme_route>THARouteMalformed)return out;
        if((p->ata_route==THARouteAbsent && digest_present(p->ata_mapping)) || (p->nvme_route==THARouteAbsent && digest_present(p->nvme_mapping)) ||
           (p->ata_route==THARouteAdvertised && !digest_present(p->ata_mapping)) || (p->nvme_route==THARouteAdvertised && !digest_present(p->nvme_mapping)))return out;
        if(p->ata_capability==THACapMalformed || p->nvme_capability==THACapMalformed || p->ata_route==THARouteMalformed || p->nvme_route==THARouteMalformed){out.status=THAMalformed;return out;}
        number(bytes,&used,node->registry_id);number(bytes,&used,node->parent_id);number(bytes,&used,node->parent_count);
        bytes[used++]=p->ata_capability;bytes[used++]=p->nvme_capability;bytes[used++]=p->ata_route;bytes[used++]=p->nvme_route;
        memcpy(bytes+used,p->ata_mapping,32);used+=32;memcpy(bytes+used,p->nvme_mapping,32);used+=32;
        if(i<block)continue;
        if(p->ata_capability==THACapTrue) {
            if(p->ata_route!=THARouteAdvertised || !digest_present(p->ata_mapping)){out.status=THAUnsupported;return out;}
            candidates++;out.provider=node->registry_id;out.kind=1;
        }
        if(p->nvme_capability==THACapTrue) {
            if(p->nvme_route!=THARouteAdvertised || !digest_present(p->nvme_mapping)){out.status=THAUnsupported;return out;}
            candidates++;out.provider=node->registry_id;out.kind=2;
        }
    }
    if(candidates!=1){out.status=candidates?THAAmbiguous:THAUnsupported;out.provider=0;out.kind=0;return out;}
    if(used>sizeof(bytes) || !CC_SHA256(bytes,(CC_LONG)used,out.seal)){out.status=THAInvalid;return out;}
    out.status=THAOK;out.node_count=(uint32_t)length;out.selected_media=binding.selected_media;out.whole_media=binding.whole_media;
    out.block_boundary=binding.block_boundary;out.endpoint=binding.endpoint;out.generation=binding.generation;
    return out;
}
int tha_revalidate(const THAAssociation *prior,const THAAssociation *observed) {
    return prior && observed && prior->status==THAOK && observed->status==THAOK && prior->node_count==observed->node_count &&
        prior->node_count>=1 && prior->node_count<=64 && prior->selected_media && prior->whole_media && prior->block_boundary && prior->endpoint && prior->generation && prior->provider &&
        (prior->kind==1 || prior->kind==2) && digest_present(prior->seal) && digest_present(observed->seal) &&
        prior->selected_media==observed->selected_media && prior->whole_media==observed->whole_media && prior->block_boundary==observed->block_boundary &&
        prior->endpoint==observed->endpoint && prior->generation==observed->generation && prior->provider==observed->provider && prior->kind==observed->kind &&
        memcmp(prior->seal,observed->seal,sizeof(prior->seal))==0;
}
