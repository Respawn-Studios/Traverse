#include "THWire.h"
#include <string.h>

static uint64_t read64(const uint8_t *bytes) {
    uint64_t value = 0;
    for (unsigned i = 0; i < 8; ++i) value |= (uint64_t)bytes[i] << (8 * i);
    return value;
}
static void write32(uint8_t *bytes, uint32_t value) {
    for (unsigned i = 0; i < 4; ++i) bytes[i] = (uint8_t)(value >> (8 * i));
}
static void write64(uint8_t *bytes, uint64_t value) {
    for (unsigned i = 0; i < 8; ++i) bytes[i] = (uint8_t)(value >> (8 * i));
}

int th_wire_decode_request(const uint8_t *bytes, size_t count, THWireRequest *out) {
    if (!out) return 0;
    memset(out, 0, sizeof(*out));
    if (!bytes || count != THRequestBytes || memcmp(bytes, "THR2", 4) != 0 || bytes[4] != 2) return 0;
    for (size_t i = 5; i < 8; ++i) if (bytes[i] != 0) return 0;
    for (size_t i = 56; i < THRequestBytes; ++i) if (bytes[i] != 0) return 0;
    uint64_t selected = read64(bytes + 24), whole = read64(bytes + 32);
    uint64_t block = read64(bytes + 40), generation = read64(bytes + 48);
    if (!selected || !whole || !block || !generation) return 0;
    memcpy(out->nonce, bytes + 8, sizeof(out->nonce));
    out->selected_media = selected; out->outer_whole = whole;
    out->block_boundary = block; out->generation = generation;
    return 1;
}

int th_wire_encode_response(const THWireRequest *request, const THNativeOutcome *value,
                            uint8_t *bytes, size_t count) {
    if (!request || !value || !bytes || count != THResponseBytes) return 0;
    memset(bytes, 0, count);
    memcpy(bytes, "THS2", 4);
    bytes[4] = 2;
    memcpy(bytes + 8, request->nonce, sizeof(request->nonce));
    write32(bytes + 24, value->status);
    write32(bytes + 28, value->smart.stage);
    write32(bytes + 32, value->smart.code_domain);
    write32(bytes + 36, (uint32_t)value->smart.primary_code);
    write32(bytes + 40, (uint32_t)value->smart.destroy_code);
    bytes[44] = value->smart.warning_valid;
    bytes[45] = value->smart.warning_byte;
    bytes[46] = value->smart.provider_kind;
    bytes[47] = value->cleanup_confirmed;
    write64(bytes + 48, value->provider);
    write64(bytes + 56, (uint64_t)value->captured_seconds);
    write32(bytes + 64, (uint32_t)value->captured_nanoseconds);
    if (value->smart.warning_valid && value->smart.provider_kind == THKindNVMe && value->smart.nvme.valid) {
        const THNVMeMeasurements *nvme = &value->smart.nvme;
        bytes[68] = 1;
        bytes[69] = (uint8_t)nvme->temperature_kelvin;
        bytes[70] = (uint8_t)(nvme->temperature_kelvin >> 8);
        bytes[71] = nvme->available_spare;
        bytes[72] = nvme->spare_threshold;
        bytes[73] = nvme->percentage_used;
        memcpy(bytes + 80, nvme->counters_le, sizeof(nvme->counters_le));
    }
    return 1;
}
