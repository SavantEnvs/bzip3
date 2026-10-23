/* libFuzzer port of examples/fuzz-decode-block.c: bz3_decode_block on attacker-controlled
 * block metadata + payload. Input layout: u32 orig_size | u32 compressed_size | u32 buffer_size | block bytes. */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "libbz3.h"

#define KiB(x) ((x) * 1024)
#define MAX_BUFFER_SIZE (1u << 24)

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size < 12) return -1;

    uint32_t orig_size, comp_size, buffer_size;
    memcpy(&orig_size, data, 4);
    memcpy(&comp_size, data + 4, 4);
    memcpy(&buffer_size, data + 8, 4);
    if (buffer_size > MAX_BUFFER_SIZE) return -1;

    struct bz3_state *state = bz3_new(KiB(65));
    if (!state) return -1;

    uint8_t *buffer = calloc(buffer_size ? buffer_size : 1, 1);
    if (!buffer) {
        bz3_free(state);
        return -1;
    }

    size_t data_len = size - 12;
    memcpy(buffer, data + 12, data_len < buffer_size ? data_len : buffer_size);

    bz3_decode_block(state, buffer, buffer_size, (int32_t)comp_size, (int32_t)orig_size);

    free(buffer);
    bz3_free(state);
    return 0;
}
