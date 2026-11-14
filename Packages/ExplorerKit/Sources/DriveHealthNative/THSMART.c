#include "THSMART.h"
#include <string.h>

_Static_assert(sizeof(NVMeSMARTData) == 512, "SDK NVMe data changed");
_Static_assert(offsetof(NVMeSMARTData, CRITICAL_WARNING) == 0, "SDK warning offset");
_Static_assert(offsetof(NVMeSMARTData, TEMPERATURE) == 1, "SDK packed temperature");
_Static_assert(offsetof(NVMeSMARTData, AVAILABLE_SPARE) == 3, "SDK spare offset");
_Static_assert(offsetof(NVMeSMARTData, PERCENTAGE_USED) == 5, "SDK usage offset");
_Static_assert(offsetof(NVMeSMARTData, DATA_UNITS_READ) == 32, "SDK counters offset");
_Static_assert(offsetof(NVMeSMARTData, DATA_UNITS_WRITTEN) == 48, "SDK written offset");
_Static_assert(offsetof(NVMeSMARTData, HOST_READ_COMMANDS) == 64, "SDK read commands offset");
_Static_assert(offsetof(NVMeSMARTData, HOST_WRITE_COMMANDS) == 80, "SDK write commands offset");
_Static_assert(offsetof(NVMeSMARTData, CONTROLLER_BUSY_TIME) == 96, "SDK busy offset");
_Static_assert(offsetof(NVMeSMARTData, POWER_CYCLES) == 112, "SDK cycles offset");
_Static_assert(offsetof(NVMeSMARTData, POWER_ON_HOURS) == 128, "SDK hours offset");
_Static_assert(offsetof(NVMeSMARTData, UNSAFE_SHUTDOWNS) == 144, "SDK shutdown offset");
_Static_assert(offsetof(NVMeSMARTData, MEDIA_ERRORS) == 160, "SDK errors offset");
_Static_assert(offsetof(NVMeSMARTData, NUM_ERROR_INFO_LOG_ENTRIES) == 176, "SDK log count offset");
_Static_assert(offsetof(NVMeSMARTData, RESERVED2) == 192, "SDK reserved tail");
_Static_assert(__builtin_types_compatible_p(THCreatePlugin,
    __typeof__(&IOCreatePlugInInterfaceForService)), "SDK creation type changed");
_Static_assert(__builtin_types_compatible_p(THDestroyPlugin,
    __typeof__(&IODestroyPlugInInterface)), "SDK destruction type changed");

int32_t th_smart_no_interface_hresult(void) { return (int32_t)E_NOINTERFACE; }

static void failure(THSMARTResult *out, uint32_t stage, uint32_t domain, int32_t code) {
    out->stage = stage;
    out->code_domain = domain;
    out->primary_code = code;
    out->warning_valid = 0;
    out->warning_byte = 0;
    memset(&out->nvme, 0, sizeof(out->nvme));
}

void th_smart_read_once(io_service_t service, uint8_t kind,
                        const THSMARTBackend *backend, THSMARTResult *out) {
    if (out == NULL) return;
    memset(out, 0, sizeof(*out));
    out->provider_kind = kind;
    failure(out, THStageAdmission, THDomainContract, THContractInvalidArgument);
    if (service == IO_OBJECT_NULL || (kind != THKindATA && kind != THKindNVMe)
        || backend == NULL || backend->create == NULL || backend->destroy == NULL) return;

    IOCFPlugInInterface **plugin = NULL;
    IOATASMARTInterface **ata = NULL;
    IONVMeSMARTInterface **nvme = NULL;
    SInt32 score = 0;
    CFUUIDRef user_client = kind == THKindATA ? kIOATASMARTUserClientTypeID : kIONVMeSMARTUserClientTypeID;
    IOReturn created = backend->create(service, user_client, kIOCFPlugInInterfaceID, &plugin, &score);
    if (created != kIOReturnSuccess) {
        failure(out, THStageCreate, THDomainKernel, created);
        goto cleanup;
    }
    if (plugin == NULL || *plugin == NULL) {
        failure(out, THStageCreate, THDomainContract, THContractMissingPlugin);
        goto cleanup;
    }
    if ((*plugin)->QueryInterface == NULL) {
        failure(out, THStageQuery, THDomainContract, THContractMissingQuery);
        goto cleanup;
    }
    CFUUIDRef interface_id = kind == THKindATA ? kIOATASMARTInterfaceID : kIONVMeSMARTInterfaceID;
    void *queried = NULL;
    HRESULT status = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(interface_id), &queried);
    if (kind == THKindATA) ata = (IOATASMARTInterface **)queried;
    else nvme = (IONVMeSMARTInterface **)queried;
    if (status != S_OK) {
        failure(out, THStageQuery, THDomainHRESULT, status);
        goto cleanup;
    }
    if (queried == NULL || (kind == THKindATA ? *ata == NULL : *nvme == NULL)) {
        failure(out, THStageQuery, THDomainContract, THContractMissingInterface);
        goto cleanup;
    }
    if (kind == THKindATA ? (*ata)->Release == NULL : (*nvme)->Release == NULL) {
        failure(out, THStageQuery, THDomainContract, THContractMissingRelease);
        out->cleanup_incomplete = 1;
        goto cleanup;
    }

    IOReturn read_status;
    uint8_t warning;
    if (kind == THKindATA) {
        if ((*ata)->SMARTReturnStatus == NULL) {
            failure(out, THStageRead, THDomainContract, THContractMissingRead);
            goto cleanup;
        }
        Boolean exceeded = false;
        read_status = (*ata)->SMARTReturnStatus(ata, &exceeded);
        warning = exceeded != 0;
    } else {
        if ((*nvme)->SMARTReadData == NULL) {
            failure(out, THStageRead, THDomainContract, THContractMissingRead);
            goto cleanup;
        }
        NVMeSMARTData data;
        memset(&data, 0, sizeof(data));
        read_status = (*nvme)->SMARTReadData(nvme, &data);
        warning = data.CRITICAL_WARNING;
        if (read_status == kIOReturnSuccess) {
            const uint8_t *bytes = (const uint8_t *)&data;
            out->nvme.valid = 1;
            out->nvme.temperature_kelvin = (uint16_t)bytes[1] | (uint16_t)bytes[2] << 8;
            out->nvme.available_spare = data.AVAILABLE_SPARE;
            out->nvme.spare_threshold = data.AVAILABLE_SPARE_THRESHOLD;
            out->nvme.percentage_used = data.PERCENTAGE_USED;
            memcpy(out->nvme.counters_le, bytes + 32, sizeof(out->nvme.counters_le));
        }
    }
    if (read_status != kIOReturnSuccess) {
        failure(out, THStageRead, THDomainIOReturn, read_status);
        goto cleanup;
    }
    out->stage = THStageComplete;
    out->code_domain = THDomainNone;
    out->primary_code = 0;
    out->warning_valid = 1;
    out->warning_byte = warning;

cleanup:
    if (ata != NULL && *ata != NULL) {
        if ((*ata)->Release != NULL) (*ata)->Release(ata);
        else out->cleanup_incomplete = 1;
    }
    if (nvme != NULL && *nvme != NULL) {
        if ((*nvme)->Release != NULL) (*nvme)->Release(nvme);
        else out->cleanup_incomplete = 1;
    }
    if (plugin != NULL && *plugin != NULL) {
        out->destroy_code = backend->destroy(plugin);
        if (out->destroy_code != kIOReturnSuccess && out->code_domain == THDomainNone)
            failure(out, THStageCleanup, THDomainIOReturn, out->destroy_code);
    }
    if (out->cleanup_incomplete) out->warning_valid = 0;
    if (!out->warning_valid) {
        out->warning_byte = 0;
        memset(&out->nvme, 0, sizeof(out->nvme));
    }
}
