/* libFuzzer port of examples/fuzz-round-trip.c: encode a block, decode it back, require identity. */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "libbz3.h"

#define KiB(x) ((x) * 1024)
#define DEFAULT_BLOCK_SIZE KiB(65)

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size == 0) return -1;

    size_t block_size = size > DEFAULT_BLOCK_SIZE ? size : DEFAULT_BLOCK_SIZE;
    struct bz3_state *state = bz3_new((int32_t)block_size);
    if (!state) return -1;

    size_t buf_len = bz3_bound(size);
    uint8_t *buf = malloc(buf_len);
    if (!buf) {
        bz3_free(state);
        return -1;
    }
    memcpy(buf, data, size);

    int32_t comp_size = bz3_encode_block(state, buf, (int32_t)size);
    if (comp_size < 0) abort();

    int32_t dec = bz3_decode_block(state, buf, buf_len, comp_size, (int32_t)size);
    if (dec != (int32_t)size) abort();
    if (memcmp(buf, data, size) != 0) abort();

    free(buf);
    bz3_free(state);
    return 0;
}
