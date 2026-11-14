#ifndef TRAVERSE_HEALTH_SMART_H
#define TRAVERSE_HEALTH_SMART_H

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/ata/ATASMARTLib.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>
#include <stddef.h>
#include <stdint.h>

enum { THKindATA = 1, THKindNVMe = 2 };
enum { THStageAdmission = 1, THStageCreate = 2, THStageQuery = 3,
       THStageRead = 4, THStageCleanup = 5, THStageComplete = 6 };
enum { THDomainNone = 0, THDomainKernel = 1, THDomainHRESULT = 2,
       THDomainIOReturn = 3, THDomainContract = 4 };
enum { THContractInvalidArgument = 1, THContractMissingPlugin = 2,
       THContractMissingQuery = 3, THContractMissingInterface = 4,
       THContractMissingRead = 5, THContractMissingRelease = 6 };

typedef IOReturn (*THCreatePlugin)(io_service_t, CFUUIDRef, CFUUIDRef,
                                  IOCFPlugInInterface ***, SInt32 *);
typedef IOReturn (*THDestroyPlugin)(IOCFPlugInInterface **);

/* Internal seam. A nonnull output is a valid owned SDK COM object, including
 * on an injected failure. Arbitrary/unowned pointers are outside this contract.
 * Native provider acquisition and backend creation are intentionally absent. */
typedef struct {
    THCreatePlugin create;
    THDestroyPlugin destroy;
} THSMARTBackend;

typedef struct {
    uint8_t valid;
    uint16_t temperature_kelvin;
    uint8_t available_spare;
    uint8_t spare_threshold;
    uint8_t percentage_used;
    /* Ten128-bit little-endian SDK counters, bytes32 through191 only.
     * No reserved tail, Identify data, serial number or pointer crosses here. */
    uint8_t counters_le[160];
} THNVMeMeasurements;

typedef struct {
    uint32_t stage;
    uint32_t code_domain;
    int32_t primary_code;
    int32_t destroy_code;
    uint8_t warning_valid;
    uint8_t warning_byte;
    uint8_t provider_kind;
    uint8_t cleanup_incomplete;
    THNVMeMeasurements nvme;
} THSMARTResult;

/* Synchronous. The caller retains the provider lease until this returns,
 * including every Release/destroy call. No buffer/pointer escapes the call. */
void th_smart_read_once(io_service_t borrowed_service, uint8_t kind,
                        const THSMARTBackend *backend, THSMARTResult *result);
/* The public SDK's E_NOINTERFACE macro overflows its Swift imported Int32
 * expression. Convert in C to retain the exact SDK HRESULT bit pattern. */
int32_t th_smart_no_interface_hresult(void);

#endif
