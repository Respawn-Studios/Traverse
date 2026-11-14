#include "THAcquisition.h"
#include "THAssociation.h"
#include <IOKit/IOKitKeys.h>
#include <IOKit/storage/IOStorageProtocolCharacteristics.h>
#include <string.h>
#include <time.h>

enum { THMaximumNodes = 64 };
enum { THTransportNone = 0, THTransportATA = 1, THTransportNVMe = 2 };

typedef struct {
    io_service_t handles[THMaximumNodes];
    THANode nodes[THMaximumNodes];
    size_t count;
    uint8_t transport;
    THAAssociation association;
} THObservation;

static void release_observation(THObservation *value) {
    for (size_t i = 0; i < value->count; ++i) {
        if (value->handles[i] != IO_OBJECT_NULL) IOObjectRelease(value->handles[i]);
        value->handles[i] = IO_OBJECT_NULL;
    }
    value->count = 0;
}

static int equal_string(CFTypeRef value, const char *expected) {
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) return 0;
    CFStringRef reference = CFStringCreateWithCStringNoCopy(
        kCFAllocatorDefault, expected, kCFStringEncodingUTF8, kCFAllocatorNull);
    if (!reference) return 0;
    int matches = CFStringCompare((CFStringRef)value, reference, 0) == kCFCompareEqualTo;
    CFRelease(reference);
    return matches;
}

/* A direct, typed block-device observation only. External native ATA/NVMe can
 * use the same public plugin; USB/Thunderbolt wrappers remain unsupported. */
uint8_t th_native_transport(CFTypeRef raw) {
    if (!raw) return THTransportNone;
    uint8_t result = THTransportNone;
    if (CFGetTypeID(raw) == CFDictionaryGetTypeID()) {
        CFDictionaryRef values = (CFDictionaryRef)raw;
        CFTypeRef location = CFDictionaryGetValue(values, CFSTR(kIOPropertyPhysicalInterconnectLocationKey));
        CFTypeRef type = CFDictionaryGetValue(values, CFSTR(kIOPropertyPhysicalInterconnectTypeKey));
        if (equal_string(location, kIOPropertyInternalKey) || equal_string(location, kIOPropertyExternalKey)) {
            if (equal_string(type, kIOPropertyPhysicalInterconnectTypeATA) ||
                equal_string(type, kIOPropertyPhysicalInterconnectTypeSerialATA)) result = THTransportATA;
            else if (equal_string(type, kIOPropertyPhysicalInterconnectTypePCI) ||
                     equal_string(type, kIOPropertyPhysicalInterconnectTypePCIExpress) ||
                     equal_string(type, kIOPropertyPhysicalInterconnectTypeAppleFabric)) result = THTransportNVMe;
        }
    }
    return result;
}

static uint8_t transport_of(io_service_t block) {
    CFTypeRef raw = IORegistryEntryCreateCFProperty(block,
        CFSTR(kIOPropertyProtocolCharacteristicsKey), kCFAllocatorDefault, 0);
    uint8_t result = th_native_transport(raw);
    if (raw) CFRelease(raw);
    return result;
}

static THAProperties properties_of(io_service_t service) {
    CFTypeRef ata = IORegistryEntryCreateCFProperty(service, CFSTR(kIOPropertySMARTCapableKey), kCFAllocatorDefault, 0);
    CFTypeRef nvme = IORegistryEntryCreateCFProperty(service, CFSTR(kIOPropertyNVMeSMARTCapableKey), kCFAllocatorDefault, 0);
    CFTypeRef plugins = IORegistryEntryCreateCFProperty(service, CFSTR(kIOCFPlugInTypesKey), kCFAllocatorDefault, 0);
    THAProperties result = tha_parse_properties(ata, nvme, plugins);
    if (ata) CFRelease(ata);
    if (nvme) CFRelease(nvme);
    if (plugins) CFRelease(plugins);
    return result;
}

static uint32_t observe(uint64_t selected, uint64_t whole, uint64_t block,
                        uint64_t generation, THObservation *out, THSMARTResult *failure) {
    memset(out, 0, sizeof(*out));
    CFMutableDictionaryRef match = IORegistryEntryIDMatching(selected);
    if (!match) return THNativeUnavailable;
    io_service_t current = IOServiceGetMatchingService(kIOMainPortDefault, match);
    if (current == IO_OBJECT_NULL) return THNativeChanged;
    if (!IOObjectConformsTo(current, "IOMedia")) { IOObjectRelease(current); return THNativeUnsupported; }
    uint32_t status = THNativeInvalid;
    int found_whole = 0, found_block = 0, reached_endpoint = 0;
    for (size_t i = 0; i < THMaximumNodes; ++i) {
        out->handles[i] = current;
        out->count = i + 1;
        uint64_t id = 0;
        kern_return_t result = IORegistryEntryGetRegistryEntryID(current, &id);
        if (result != KERN_SUCCESS || !id) {
            if (failure && result != KERN_SUCCESS) {
                failure->stage = THStageAdmission; failure->code_domain = THDomainKernel;
                failure->primary_code = result;
            }
            goto done;
        }
        for (size_t j = 0; j < i; ++j) if (out->nodes[j].registry_id == id) goto done;
        out->nodes[i].registry_id = id;
        out->nodes[i].properties = properties_of(current);
        if (id == whole) {
            CFTypeRef whole_value = IORegistryEntryCreateCFProperty(current, CFSTR("Whole"), kCFAllocatorDefault, 0);
            found_whole = IOObjectConformsTo(current, "IOMedia") && whole_value &&
                CFGetTypeID(whole_value) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)whole_value);
            if (whole_value) CFRelease(whole_value);
            if (!found_whole) { status = THNativeUnsupported; goto done; }
        }
        if (id == block) {
            found_block = IOObjectConformsTo(current, "IOBlockStorageDevice") != 0;
            out->transport = found_block ? transport_of(current) : THTransportNone;
            if (!found_block || !out->transport) { status = THNativeUnsupported; goto done; }
        }
        io_iterator_t iterator = IO_OBJECT_NULL;
        result = IORegistryEntryGetParentIterator(current, kIOServicePlane, &iterator);
        if (result != KERN_SUCCESS || iterator == IO_OBJECT_NULL) {
            if (failure && result != KERN_SUCCESS) {
                failure->stage = THStageAdmission; failure->code_domain = THDomainKernel;
                failure->primary_code = result;
            }
            status = THNativeUnavailable; goto done;
        }
        io_service_t parent = IOIteratorNext(iterator);
        io_service_t second = IOIteratorNext(iterator);
        int valid = IOIteratorIsValid(iterator) != 0;
        IOObjectRelease(iterator);
        if (second != IO_OBJECT_NULL) IOObjectRelease(second);
        if (!valid || second != IO_OBJECT_NULL) {
            if (parent != IO_OBJECT_NULL) IOObjectRelease(parent);
            status = THNativeUnsupported; goto done;
        }
        if (parent == IO_OBJECT_NULL) { reached_endpoint = 1; break; }
        uint64_t parent_id = 0;
        result = IORegistryEntryGetRegistryEntryID(parent, &parent_id);
        if (result != KERN_SUCCESS || !parent_id) {
            if (failure && result != KERN_SUCCESS) {
                failure->stage = THStageAdmission; failure->code_domain = THDomainKernel;
                failure->primary_code = result;
            }
            IOObjectRelease(parent); status = THNativeChanged; goto done;
        }
        out->nodes[i].parent_count = 1;
        out->nodes[i].parent_id = parent_id;
        current = parent;
    }
    if (!reached_endpoint || !found_whole || !found_block) { status = THNativeUnsupported; goto done; }
    THABinding binding = { .selected_media = selected, .whole_media = whole,
        .block_boundary = block, .endpoint = out->nodes[out->count - 1].registry_id,
        .generation = generation, .scope = THAPhysical };
    out->association = tha_associate(out->nodes, out->count, binding);
    if (out->association.status != THAOK) {
        status = out->association.status == THAChanged ? THNativeChanged : THNativeUnsupported;
        goto done;
    }
    if ((out->transport == THTransportATA && out->association.kind != THKindATA) ||
        (out->transport == THTransportNVMe && out->association.kind != THKindNVMe)) {
        status = THNativeUnsupported; goto done;
    }
    return THNativeSample;
done:
    release_observation(out);
    return status;
}

void th_native_read_once(uint64_t selected_media, uint64_t outer_whole,
                         uint64_t block_boundary, uint64_t generation,
                         THNativeOutcome *out) {
    if (!out) return;
    memset(out, 0, sizeof(*out));
    out->status = THNativeInvalid;
    out->cleanup_confirmed = 1; /* No native plugin has been created yet. */
    if (!selected_media || !outer_whole || !block_boundary || !generation ||
        selected_media == block_boundary || outer_whole == block_boundary) return;
    THObservation before;
    uint32_t initial = observe(selected_media, outer_whole, block_boundary, generation, &before, &out->smart);
    if (initial != THNativeSample) { out->status = initial; return; }
    THObservation preflight;
    uint32_t refreshed = observe(selected_media, outer_whole, block_boundary, generation, &preflight, NULL);
    int same = refreshed == THNativeSample && preflight.transport == before.transport &&
        tha_revalidate(&before.association, &preflight.association);
    if (refreshed == THNativeSample) release_observation(&preflight);
    if (!same) { out->status = THNativeChanged; release_observation(&before); return; }
    io_service_t provider = IO_OBJECT_NULL;
    for (size_t i = 0; i < before.count; ++i)
        if (before.nodes[i].registry_id == before.association.provider) provider = before.handles[i];
    if (provider == IO_OBJECT_NULL) { out->status = THNativeInvalid; release_observation(&before); return; }
    out->provider = before.association.provider;
    THSMARTBackend backend = { .create = IOCreatePlugInInterfaceForService,
        .destroy = IODestroyPlugInInterface };
    th_smart_read_once(provider, before.association.kind, &backend, &out->smart);
    if (out->smart.cleanup_incomplete || out->smart.destroy_code != kIOReturnSuccess) {
        /* The one-shot process exits without claiming that this native lease
         * was cleaned up. Its parent permanently fences device actions. */
        out->status = THNativeUncertain;
        out->cleanup_confirmed = 0;
        return;
    }
    struct timespec captured = {0};
    if (out->smart.warning_valid && clock_gettime(CLOCK_REALTIME, &captured) == 0) {
        out->captured_seconds = captured.tv_sec;
        out->captured_nanoseconds = (int32_t)captured.tv_nsec;
    }
    THObservation after;
    uint32_t final = observe(selected_media, outer_whole, block_boundary, generation, &after, NULL);
    same = final == THNativeSample && after.transport == before.transport &&
        tha_revalidate(&before.association, &after.association);
    if (final == THNativeSample) release_observation(&after);
    release_observation(&before);
    if (!same) {
        out->status = THNativeChanged;
        out->smart.warning_valid = 0;
        out->smart.warning_byte = 0;
        return;
    }
    out->status = out->smart.warning_valid ? THNativeSample : THNativeReadFailure;
}
