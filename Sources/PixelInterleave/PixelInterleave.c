// Written with NEON intrinsics so the loops stay fast in an unoptimized (debug) build of
// the app: each intrinsic is one instruction even at -O0, and handles 8 or 16 samples.

#include "PixelInterleave.h"
#include <string.h>

#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif

void pi_interleave_8(const uint8_t *cb, size_t cbStride,
                     const uint8_t *cr, size_t crStride,
                     uint8_t *dst, size_t dstStride,
                     size_t width, size_t height) {
    for (size_t y = 0; y < height; y++) {
        const uint8_t *u = cb + y * cbStride;
        const uint8_t *v = cr + y * crStride;
        uint8_t *out = dst + y * dstStride;
        size_t x = 0;
#if defined(__ARM_NEON)
        for (; x + 16 <= width; x += 16) {
            uint8x16x2_t pair;
            pair.val[0] = vld1q_u8(u + x);
            pair.val[1] = vld1q_u8(v + x);
            vst2q_u8(out + 2 * x, pair);
        }
#endif
        for (; x < width; x++) {
            out[2 * x] = u[x];
            out[2 * x + 1] = v[x];
        }
    }
}

void pi_interleave_16(const uint16_t *cb, size_t cbStride,
                      const uint16_t *cr, size_t crStride,
                      uint16_t *dst, size_t dstStride,
                      size_t width, size_t height, int bits) {
    const int shift = 16 - bits;
    for (size_t y = 0; y < height; y++) {
        const uint16_t *u = (const uint16_t *)((const uint8_t *)cb + y * cbStride);
        const uint16_t *v = (const uint16_t *)((const uint8_t *)cr + y * crStride);
        uint16_t *out = (uint16_t *)((uint8_t *)dst + y * dstStride);
        size_t x = 0;
#if defined(__ARM_NEON)
        const int16x8_t amount = vdupq_n_s16((int16_t)shift);
        for (; x + 8 <= width; x += 8) {
            uint16x8x2_t pair;
            pair.val[0] = vshlq_u16(vld1q_u16(u + x), amount);
            pair.val[1] = vshlq_u16(vld1q_u16(v + x), amount);
            vst2q_u16(out + 2 * x, pair);
        }
#endif
        for (; x < width; x++) {
            out[2 * x] = (uint16_t)(u[x] << shift);
            out[2 * x + 1] = (uint16_t)(v[x] << shift);
        }
    }
}

void pi_shift_16(const uint16_t *src, size_t srcStride,
                 uint16_t *dst, size_t dstStride,
                 size_t width, size_t height, int bits) {
    const int shift = 16 - bits;
    for (size_t y = 0; y < height; y++) {
        const uint16_t *in = (const uint16_t *)((const uint8_t *)src + y * srcStride);
        uint16_t *out = (uint16_t *)((uint8_t *)dst + y * dstStride);
        size_t x = 0;
#if defined(__ARM_NEON)
        const int16x8_t amount = vdupq_n_s16((int16_t)shift);
        for (; x + 8 <= width; x += 8) {
            vst1q_u16(out + x, vshlq_u16(vld1q_u16(in + x), amount));
        }
#endif
        for (; x < width; x++) {
            out[x] = (uint16_t)(in[x] << shift);
        }
    }
}

void pi_copy_8(const uint8_t *src, size_t srcStride,
               uint8_t *dst, size_t dstStride,
               size_t width, size_t height) {
    for (size_t y = 0; y < height; y++) {
        memcpy(dst + y * dstStride, src + y * srcStride, width);
    }
}
