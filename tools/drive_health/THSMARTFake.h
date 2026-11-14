#ifndef TRAVERSE_HEALTH_SMART_FAKE_H
#define TRAVERSE_HEALTH_SMART_FAKE_H
#include "THSMART.h"

typedef struct THSMARTFake THSMARTFake;
typedef struct {
    uint8_t kind;
    uint8_t warning;
    uint8_t create_null;
    uint8_t query_null;
    uint8_t create_owned_on_failure;
    uint8_t query_owned_on_failure;
    uint8_t missing_query;
    uint8_t missing_read;
    uint8_t missing_release;
    uint8_t block_stage;
    int32_t create_code;
    int32_t query_code;
    int32_t read_code;
    int32_t stop_code;
    int32_t destroy_code;
} THSMARTFakeConfiguration;
typedef struct {
    uint32_t create;
    uint32_t query;
    uint32_t read;
    uint32_t smart_release;
    uint32_t destroy;
    uint32_t stop;
    uint32_t plugin_release;
    uint32_t forbidden;
    uint32_t plugin_references;
    uint32_t smart_references;
    uint32_t entered_block;
    uint32_t returned;
    uint32_t events[16];
    uint32_t event_count;
} THSMARTFakeCounters;

THSMARTFake *th_fake_new(THSMARTFakeConfiguration configuration);
THSMARTResult th_fake_read(THSMARTFake *fake);
int th_fake_wait_blocked(THSMARTFake *fake, uint32_t milliseconds);
void th_fake_open_gate(THSMARTFake *fake);
THSMARTFakeCounters th_fake_counters(THSMARTFake *fake);
/* Only the deliberately malformed test vtable uses this. It does not pretend
 * that a real unknown COM object has a recoverable missing Release method. */
void th_fake_restore_missing_release(THSMARTFake *fake);
void th_fake_free(THSMARTFake *fake);
#endif
