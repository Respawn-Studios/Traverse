#include "THSMARTFake.h"
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct { IOCFPlugInInterface *table; THSMARTFake *owner; } FakePlugin;
typedef struct { IOATASMARTInterface *table; THSMARTFake *owner; } FakeATA;
typedef struct { IONVMeSMARTInterface *table; THSMARTFake *owner; } FakeNVMe;
struct THSMARTFake {
    THSMARTFakeConfiguration config;
    THSMARTFakeCounters counts;
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    int gate_open;
    IOCFPlugInInterface plugin_table;
    IOATASMARTInterface ata_table;
    IONVMeSMARTInterface nvme_table;
    FakePlugin plugin;
    FakeATA ata;
    FakeNVMe nvme;
};
static _Thread_local THSMARTFake *current;

static void event(THSMARTFake *fake, uint32_t kind) {
    assert(pthread_mutex_lock(&fake->mutex) == 0);
    assert(fake->counts.event_count < 16);
    fake->counts.events[fake->counts.event_count++] = kind;
    if (kind == fake->config.block_stage) {
        fake->counts.entered_block++;
        assert(pthread_cond_broadcast(&fake->condition) == 0);
        while (!fake->gate_open) assert(pthread_cond_wait(&fake->condition, &fake->mutex) == 0);
    }
    assert(pthread_mutex_unlock(&fake->mutex) == 0);
}
static void count(THSMARTFake *fake, uint32_t *value) {
    assert(pthread_mutex_lock(&fake->mutex) == 0);
    (*value)++;
    assert(pthread_mutex_unlock(&fake->mutex) == 0);
}
static void acquire_reference(THSMARTFake *fake, uint32_t *value) {
    assert(pthread_mutex_lock(&fake->mutex) == 0);
    assert(*value == 0); *value = 1;
    assert(pthread_mutex_unlock(&fake->mutex) == 0);
}
static void release_reference(THSMARTFake *fake, uint32_t *value) {
    assert(pthread_mutex_lock(&fake->mutex) == 0);
    assert(*value == 1); *value = 0;
    assert(pthread_mutex_unlock(&fake->mutex) == 0);
}
static int uuid_equal(REFIID a, CFUUIDRef b) {
    CFUUIDBytes expected = CFUUIDGetUUIDBytes(b);
    return memcmp(&a, &expected, sizeof(expected)) == 0;
}
static ULONG plugin_release(void *pointer) {
    FakePlugin *object = pointer;
    THSMARTFake *fake = object->owner;
    assert(pointer == &fake->plugin && object->table == &fake->plugin_table);
    event(fake, 7);
    count(fake, &fake->counts.plugin_release);
    release_reference(fake, &fake->counts.plugin_references);
    return 0;
}
static ULONG smart_release(void *pointer) {
    THSMARTFake *fake;
    if (current->config.kind == THKindATA) {
        FakeATA *object = pointer; fake = object->owner;
        assert(pointer == &fake->ata && object->table == &fake->ata_table);
    } else {
        FakeNVMe *object = pointer; fake = object->owner;
        assert(pointer == &fake->nvme && object->table == &fake->nvme_table);
    }
    event(fake, 4);
    count(fake, &fake->counts.smart_release);
    release_reference(fake, &fake->counts.smart_references);
    return 0;
}
static ULONG forbidden_addref(void *pointer) {
    (void)pointer; count(current, &current->counts.forbidden); return 0;
}
static HRESULT forbidden_query(void *pointer, REFIID id, LPVOID *out) {
    (void)pointer; (void)id; *out = NULL;
    count(current, &current->counts.forbidden); return E_NOINTERFACE;
}
static HRESULT plugin_query(void *pointer, REFIID id, LPVOID *out) {
    FakePlugin *object = pointer; THSMARTFake *fake = object->owner;
    assert(pointer == &fake->plugin && object->table == &fake->plugin_table && out != NULL);
    assert(uuid_equal(id, fake->config.kind == THKindATA ? kIOATASMARTInterfaceID : kIONVMeSMARTInterfaceID));
    event(fake, 2); count(fake, &fake->counts.query);
    *out = NULL;
    if (!fake->config.query_null && (fake->config.query_code == S_OK || fake->config.query_owned_on_failure)) {
        *out = fake->config.kind == THKindATA ? (void *)&fake->ata : (void *)&fake->nvme;
        acquire_reference(fake, &fake->counts.smart_references);
    }
    return fake->config.query_code;
}
static IOReturn ata_status(void *pointer, Boolean *exceeded) {
    FakeATA *object = pointer; THSMARTFake *fake = object->owner;
    assert(pointer == &fake->ata && object->table == &fake->ata_table && exceeded != NULL);
    event(fake, 3); count(fake, &fake->counts.read);
    *exceeded = fake->config.warning;
    return fake->config.read_code;
}
static IOReturn nvme_data(void *pointer, NVMeSMARTData *data) {
    FakeNVMe *object = pointer; THSMARTFake *fake = object->owner;
    assert(pointer == &fake->nvme && object->table == &fake->nvme_table && data != NULL);
    event(fake, 3); count(fake, &fake->counts.read);
    memset(data, 0x6d, sizeof(*data));
    data->CRITICAL_WARNING = fake->config.warning;
    /* Adjacent and high-half bytes differ so an ABI/layout mistake is visible. */
    data->TEMPERATURE = 0x1234;
    data->DATA_UNITS_READ[1] = 0xfedcba9876543210ULL;
    return fake->config.read_code;
}
static IOReturn forbidden_enable(void *pointer, Boolean value) {
    (void)pointer; (void)value; count(current, &current->counts.forbidden); return kIOReturnUnsupported;
}
static IOReturn forbidden_identify(void *pointer, void *data, uint32_t namespace_id) {
    (void)pointer; (void)data; (void)namespace_id;
    count(current, &current->counts.forbidden); return kIOReturnUnsupported;
}
static IOReturn forbidden_log(void *pointer, void *data, uint32_t id, uint32_t words) {
    (void)pointer; (void)data; (void)id; (void)words;
    count(current, &current->counts.forbidden); return kIOReturnUnsupported;
}
static IOReturn plugin_stop(void *pointer) {
    FakePlugin *object = pointer; THSMARTFake *fake = object->owner;
    assert(pointer == &fake->plugin);
    event(fake, 6); count(fake, &fake->counts.stop);
    return fake->config.stop_code;
}
static IOReturn fake_create(io_service_t service, CFUUIDRef user, CFUUIDRef interface_id,
                             IOCFPlugInInterface ***out, SInt32 *score) {
    THSMARTFake *fake = current;
    assert(fake != NULL && service == 0x54524156 && out != NULL && score != NULL);
    assert(CFEqual(user, fake->config.kind == THKindATA ? kIOATASMARTUserClientTypeID : kIONVMeSMARTUserClientTypeID));
    assert(CFEqual(interface_id, kIOCFPlugInInterfaceID));
    event(fake, 1); count(fake, &fake->counts.create);
    *out = NULL; *score = 17;
    if (!fake->config.create_null && (fake->config.create_code == kIOReturnSuccess || fake->config.create_owned_on_failure)) {
        *out = (IOCFPlugInInterface **)&fake->plugin;
        acquire_reference(fake, &fake->counts.plugin_references);
    }
    return fake->config.create_code;
}
static IOReturn fake_destroy(IOCFPlugInInterface **pointer) {
    FakePlugin *object = (FakePlugin *)pointer; THSMARTFake *fake = object->owner;
    assert(pointer == (IOCFPlugInInterface **)&fake->plugin);
    event(fake, 5); count(fake, &fake->counts.destroy);
    IOReturn stopped = (*pointer)->Stop(pointer);
    (*pointer)->Release(pointer);
    return fake->config.destroy_code != kIOReturnSuccess ? fake->config.destroy_code : stopped;
}
THSMARTFake *th_fake_new(THSMARTFakeConfiguration configuration) {
    assert(configuration.kind == THKindATA || configuration.kind == THKindNVMe);
    THSMARTFake *fake = calloc(1, sizeof(*fake)); assert(fake != NULL);
    fake->config = configuration;
    assert(pthread_mutex_init(&fake->mutex, NULL) == 0);
    assert(pthread_cond_init(&fake->condition, NULL) == 0);
    fake->plugin_table.QueryInterface = configuration.missing_query ? NULL : plugin_query;
    fake->plugin_table.AddRef = forbidden_addref;
    fake->plugin_table.Release = plugin_release;
    fake->plugin_table.Stop = plugin_stop;
    fake->ata_table.QueryInterface = forbidden_query;
    fake->ata_table.AddRef = forbidden_addref;
    fake->ata_table.Release = configuration.missing_release ? NULL : smart_release;
    fake->ata_table.SMARTEnableDisableOperations = forbidden_enable;
    fake->ata_table.SMARTEnableDisableAutosave = forbidden_enable;
    fake->ata_table.SMARTExecuteOffLineImmediate = forbidden_enable;
    fake->ata_table.SMARTReturnStatus = configuration.missing_read ? NULL : ata_status;
    fake->nvme_table.QueryInterface = forbidden_query;
    fake->nvme_table.AddRef = forbidden_addref;
    fake->nvme_table.Release = configuration.missing_release ? NULL : smart_release;
    fake->nvme_table.SMARTReadData = configuration.missing_read ? NULL : nvme_data;
    fake->nvme_table.GetIdentifyData = forbidden_identify;
    fake->nvme_table.GetLogPage = forbidden_log;
    fake->plugin = (FakePlugin){ &fake->plugin_table, fake };
    fake->ata = (FakeATA){ &fake->ata_table, fake };
    fake->nvme = (FakeNVMe){ &fake->nvme_table, fake };
    return fake;
}
THSMARTResult th_fake_read(THSMARTFake *fake) {
    assert(current == NULL); current = fake;
    THSMARTBackend backend = { fake_create, fake_destroy };
    THSMARTResult result;
    th_smart_read_once(0x54524156, fake->config.kind, &backend, &result);
    count(fake, &fake->counts.returned);
    current = NULL;
    return result;
}
int th_fake_wait_blocked(THSMARTFake *fake, uint32_t milliseconds) {
    struct timespec until; assert(clock_gettime(CLOCK_REALTIME, &until) == 0);
    until.tv_sec += milliseconds / 1000;
    until.tv_nsec += (long)(milliseconds % 1000) * 1000000;
    if (until.tv_nsec >= 1000000000) { until.tv_sec++; until.tv_nsec -= 1000000000; }
    assert(pthread_mutex_lock(&fake->mutex) == 0);
    int result = 0;
    while (fake->counts.entered_block == 0) {
        result = pthread_cond_timedwait(&fake->condition, &fake->mutex, &until);
        if (result == ETIMEDOUT) break;
        assert(result == 0);
    }
    int blocked = fake->counts.entered_block > 0;
    assert(pthread_mutex_unlock(&fake->mutex) == 0);
    return blocked;
}
void th_fake_open_gate(THSMARTFake *fake) {
    assert(pthread_mutex_lock(&fake->mutex) == 0);
    fake->gate_open = 1;
    assert(pthread_cond_broadcast(&fake->condition) == 0);
    assert(pthread_mutex_unlock(&fake->mutex) == 0);
}
THSMARTFakeCounters th_fake_counters(THSMARTFake *fake) {
    assert(pthread_mutex_lock(&fake->mutex) == 0);
    THSMARTFakeCounters value = fake->counts;
    assert(pthread_mutex_unlock(&fake->mutex) == 0);
    return value;
}
void th_fake_restore_missing_release(THSMARTFake *fake) {
    assert(fake->config.missing_release && fake->counts.returned == 1 && current == NULL);
    current = fake;
    fake->ata_table.Release = smart_release;
    fake->nvme_table.Release = smart_release;
    if (fake->config.kind == THKindATA) smart_release(&fake->ata);
    else smart_release(&fake->nvme);
    current = NULL;
}
void th_fake_free(THSMARTFake *fake) {
    assert((fake->counts.returned == 1 || (fake->counts.returned == 0 && fake->counts.create == 0))
           && fake->counts.plugin_references == 0
           && fake->counts.smart_references == 0 && fake->counts.forbidden == 0);
    assert(pthread_cond_destroy(&fake->condition) == 0);
    assert(pthread_mutex_destroy(&fake->mutex) == 0);
    memset(fake, 0, sizeof(*fake)); free(fake);
}
