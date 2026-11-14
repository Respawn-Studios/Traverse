#ifndef TRAVERSE_HEALTH_ASSOCIATION_H
#define TRAVERSE_HEALTH_ASSOCIATION_H
#include <CoreFoundation/CoreFoundation.h>
#include <stddef.h>
#include <stdint.h>

enum { THACapAbsent=0,THACapFalse=1,THACapTrue=2,THACapMalformed=3 };
enum { THARouteAbsent=0,THARouteAdvertised=1,THARouteMalformed=2 };
enum { THAOK=0,THAInvalid=1,THAMalformed=2,THAUnsupported=3,THAAmbiguous=4,THAChanged=5 };
enum { THAPhysical=1,THAVirtual=2,THAMultiStore=3 };
typedef struct {
    uint8_t ata_capability,nvme_capability,ata_route,nvme_route;
    uint8_t ata_mapping[32],nvme_mapping[32];
} THAProperties;
typedef struct {
    uint64_t registry_id,parent_id;
    uint8_t parent_count;
    THAProperties properties;
} THANode;
typedef struct {
    uint64_t selected_media,whole_media,block_boundary,endpoint,generation;
    uint8_t scope;
} THABinding;
typedef struct {
    uint32_t status,node_count;
    uint64_t selected_media,whole_media,block_boundary,endpoint,generation,provider;
    uint8_t kind,seal[32];
} THAAssociation;

/* Inputs are borrowed direct properties, never recursive inherited values.
 * Output contains no CF object, plugin path, native port or access authority. */
THAProperties tha_parse_properties(CFTypeRef ata,CFTypeRef nvme,CFTypeRef plugin_types);
THAAssociation tha_associate(const THANode *nodes,size_t count,THABinding binding);
int tha_revalidate(const THAAssociation *prior,const THAAssociation *observed);
#endif
