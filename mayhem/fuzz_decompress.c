/* libFuzzer port of examples/fuzz-decompress.c: bz3_decompress on an attacker-controlled frame.
 * Input layout: u32 output-buffer size | "BZ3v1" frame. */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "libbz3.h"

#define MAX_OUT_SIZE (1u << 26)
#define MAX_FRAME_BLOCK_SIZE (1u << 23)

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size < 8) return -1;

    uint32_t out_cap;
    memcpy(&out_cap, data, 4);
    if (out_cap > MAX_OUT_SIZE) return -1;

    const uint8_t *frame = data + 4;
    size_t frame_len = size - 4;
    if (frame_len >= 9) {
        uint32_t block_size;
        memcpy(&block_size, frame + 5, 4);
        if (block_size > MAX_FRAME_BLOCK_SIZE) return -1;
    }

    uint8_t *out = malloc(out_cap ? out_cap : 1);
    if (!out) return -1;

    size_t out_size = out_cap;
    bz3_decompress(frame, out, frame_len, &out_size);

    free(out);
    return 0;
}
