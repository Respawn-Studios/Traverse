#include "THSMARTFake.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

static unsigned cases;
static THSMARTFakeConfiguration config(uint8_t kind) {
    THSMARTFakeConfiguration value; memset(&value, 0, sizeof(value)); value.kind = kind; return value;
}
static void failed(THSMARTResult result, uint32_t stage, uint32_t domain, int32_t code) {
    assert(result.stage == stage && result.code_domain == domain && result.primary_code == code);
    assert(!result.warning_valid && result.warning_byte == 0);
    const THNVMeMeasurements empty = {0};
    assert(memcmp(&result.nvme, &empty, sizeof(empty)) == 0);
}
static void balanced(THSMARTFakeCounters value, unsigned query, unsigned read, unsigned smart, unsigned plugin) {
    assert(value.create == 1 && value.query == query && value.read == read);
    assert(value.smart_release == smart && value.destroy == plugin && value.stop == plugin && value.plugin_release == plugin);
    assert(value.smart_references == 0 && value.plugin_references == 0 && value.forbidden == 0 && value.returned == 1);
    if (plugin) {
        assert(value.event_count >= 4);
        assert(value.events[value.event_count - 3] == 5 && value.events[value.event_count - 2] == 6
               && value.events[value.event_count - 1] == 7);
        if (smart) assert(value.events[value.event_count - 4] == 4);
    }
}
static THSMARTResult exercise(THSMARTFakeConfiguration cfg, unsigned query, unsigned read, unsigned smart, unsigned plugin) {
    THSMARTFake *fake = th_fake_new(cfg); THSMARTResult result = th_fake_read(fake);
    balanced(th_fake_counters(fake), query, read, smart, plugin);
    th_fake_free(fake); cases++; return result;
}
static IOReturn must_not_create(io_service_t service, CFUUIDRef a, CFUUIDRef b,
                                 IOCFPlugInInterface ***out, SInt32 *score) {
    (void)service; (void)a; (void)b; (void)out; (void)score; assert(0); return kIOReturnError;
}
static IOReturn must_not_destroy(IOCFPlugInInterface **value) {
    (void)value; assert(0); return kIOReturnError;
}
static void arguments(void) {
    THSMARTResult result;
    THSMARTBackend backend = {must_not_create, must_not_destroy};
    th_smart_read_once(0, THKindATA, &backend, &result);
    failed(result, THStageAdmission, THDomainContract, THContractInvalidArgument);
    th_smart_read_once(17, 0, &backend, &result);
    failed(result, THStageAdmission, THDomainContract, THContractInvalidArgument);
    th_smart_read_once(17, THKindATA, NULL, &result);
    failed(result, THStageAdmission, THDomainContract, THContractInvalidArgument);
    backend.create = NULL;
    th_smart_read_once(17, THKindATA, &backend, &result);
    failed(result, THStageAdmission, THDomainContract, THContractInvalidArgument);
    backend.create = must_not_create; backend.destroy = NULL;
    th_smart_read_once(17, THKindNVMe, &backend, &result);
    failed(result, THStageAdmission, THDomainContract, THContractInvalidArgument);
    th_smart_read_once(17, THKindATA, &backend, NULL);
    cases += 6;
}
static void failure_matrix(uint8_t kind) {
    THSMARTFakeConfiguration cfg = config(kind); THSMARTResult result;
    cfg.create_code = kIOReturnNotPrivileged;
    result = exercise(cfg, 0, 0, 0, 0); failed(result, THStageCreate, THDomainKernel, cfg.create_code);
    cfg.create_owned_on_failure = 1;
    result = exercise(cfg, 0, 0, 0, 1); failed(result, THStageCreate, THDomainKernel, cfg.create_code);
    cfg = config(kind); cfg.create_null = 1;
    result = exercise(cfg, 0, 0, 0, 0); failed(result, THStageCreate, THDomainContract, THContractMissingPlugin);
    cfg = config(kind); cfg.missing_query = 1;
    result = exercise(cfg, 0, 0, 0, 1); failed(result, THStageQuery, THDomainContract, THContractMissingQuery);
    cfg = config(kind); cfg.query_code = E_NOINTERFACE;
    result = exercise(cfg, 1, 0, 0, 1); failed(result, THStageQuery, THDomainHRESULT, cfg.query_code);
    cfg.query_owned_on_failure = 1;
    result = exercise(cfg, 1, 0, 1, 1); failed(result, THStageQuery, THDomainHRESULT, cfg.query_code);
    cfg = config(kind); cfg.query_code = 1; /* S_FALSE is not the required S_OK. */
    result = exercise(cfg, 1, 0, 0, 1); failed(result, THStageQuery, THDomainHRESULT, 1);
    cfg = config(kind); cfg.query_null = 1;
    result = exercise(cfg, 1, 0, 0, 1); failed(result, THStageQuery, THDomainContract, THContractMissingInterface);
    cfg = config(kind); cfg.missing_read = 1;
    result = exercise(cfg, 1, 0, 1, 1); failed(result, THStageRead, THDomainContract, THContractMissingRead);
    const int32_t errors[] = {kIOReturnNoDevice, kIOReturnOffline, kIOReturnNotPermitted,
        kIOReturnNotPrivileged, kIOReturnUnsupported, kIOReturnBusy, kIOReturnExclusiveAccess,
        kIOReturnTimeout, kIOReturnNoResources, kIOReturnBadArgument, (int32_t)0xe0abcdef};
    for (size_t i = 0; i < sizeof(errors) / sizeof(errors[0]); i++) {
        cfg = config(kind); cfg.read_code = errors[i]; cfg.warning = 0xff;
        result = exercise(cfg, 1, 1, 1, 1); failed(result, THStageRead, THDomainIOReturn, cfg.read_code);
        cfg.warning = 0; result = exercise(cfg, 1, 1, 1, 1);
        failed(result, THStageRead, THDomainIOReturn, cfg.read_code);
    }
    cfg = config(kind); cfg.destroy_code = kIOReturnError;
    result = exercise(cfg, 1, 1, 1, 1); failed(result, THStageCleanup, THDomainIOReturn, cfg.destroy_code);
    assert(result.destroy_code == cfg.destroy_code);
    cfg.read_code = kIOReturnOffline;
    result = exercise(cfg, 1, 1, 1, 1); failed(result, THStageRead, THDomainIOReturn, cfg.read_code);
    assert(result.destroy_code == cfg.destroy_code);
    cfg = config(kind); cfg.stop_code = kIOReturnNotReady;
    result = exercise(cfg, 1, 1, 1, 1); failed(result, THStageCleanup, THDomainIOReturn, cfg.stop_code);
    assert(result.destroy_code == cfg.stop_code);
    cfg = config(kind); cfg.missing_release = 1;
    THSMARTFake *fake = th_fake_new(cfg); result = th_fake_read(fake);
    failed(result, THStageQuery, THDomainContract, THContractMissingRelease);
    assert(result.cleanup_incomplete == 1);
    THSMARTFakeCounters counts = th_fake_counters(fake);
    assert(counts.read == 0 && counts.smart_release == 0 && counts.smart_references == 1
           && counts.plugin_release == 1 && counts.plugin_references == 0);
    /* Generated-only restoration disposes the valid fake. Real malformed COM
     * cleanup is explicitly not claimed to be possible through this interface. */
    th_fake_restore_missing_release(fake); th_fake_free(fake); cases++;
}
typedef struct { THSMARTFake *fake; THSMARTResult result; } Held;
static void *read_thread(void *opaque) {
    Held *held = opaque; held->result = th_fake_read(held->fake); return NULL;
}
static void blocked_lifetimes(uint8_t kind) {
    for (uint8_t stage = 1; stage <= 7; stage++) {
        THSMARTFakeConfiguration cfg = config(kind); cfg.block_stage = stage; cfg.warning = 0x80;
        THSMARTFake *fake = th_fake_new(cfg); Held held = {fake, {0}}; pthread_t thread;
        assert(pthread_create(&thread, NULL, read_thread, &held) == 0);
        assert(th_fake_wait_blocked(fake, 3000));
        THSMARTFakeCounters counts = th_fake_counters(fake);
        assert(counts.entered_block == 1 && counts.returned == 0);
        if (stage >= 2) assert(counts.plugin_references == 1);
        if (stage == 3 || stage == 4) assert(counts.smart_references == 1);
        if (stage >= 5) assert(counts.smart_references == 0);
        th_fake_open_gate(fake);
        assert(pthread_join(thread, NULL) == 0);
        assert(held.result.warning_valid && held.result.stage == THStageComplete);
        balanced(th_fake_counters(fake), 1, 1, 1, 1);
        th_fake_free(fake); cases++;
    }
}
int main(void) {
    arguments(); failure_matrix(THKindATA); failure_matrix(THKindNVMe);
    for (unsigned warning = 0; warning < 256; warning++) {
        THSMARTFakeConfiguration cfg = config(THKindNVMe); cfg.warning = (uint8_t)warning;
        THSMARTResult result = exercise(cfg, 1, 1, 1, 1);
        assert(result.stage == THStageComplete && result.code_domain == THDomainNone
               && result.primary_code == 0 && result.destroy_code == 0 && result.warning_valid
               && result.warning_byte == warning && !result.cleanup_incomplete);
        assert(result.nvme.valid && result.nvme.temperature_kelvin == 0x1234
               && result.nvme.available_spare == 0x6d && result.nvme.percentage_used == 0x6d);
        const uint8_t high[] = {0x10,0x32,0x54,0x76,0x98,0xba,0xdc,0xfe};
        assert(memcmp(result.nvme.counters_le + 8, high, sizeof(high)) == 0);
        assert(result.nvme.counters_le[159] == 0x6d);
    }
    const uint8_t ata[] = {0, 1, 7, 255};
    for (size_t i = 0; i < sizeof(ata); i++) {
        THSMARTFakeConfiguration cfg = config(THKindATA); cfg.warning = ata[i];
        THSMARTResult result = exercise(cfg, 1, 1, 1, 1);
        assert(result.warning_valid && result.warning_byte == (ata[i] != 0));
        assert(!result.nvme.valid);
    }
    blocked_lifetimes(THKindATA); blocked_lifetimes(THKindNVMe);
    printf("{\"passed\":true,\"cases\":%u,\"warningValues\":256,\"heldNativeStages\":14,"
           "\"forbiddenCalls\":0,\"realDeviceOpens\":0,\"hardwareQualified\":false}\n", cases);
    return 0;
}
