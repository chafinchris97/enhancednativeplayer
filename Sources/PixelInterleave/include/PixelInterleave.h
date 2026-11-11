#ifndef PIXEL_INTERLEAVE_H
#define PIXEL_INTERLEAVE_H

#include <stddef.h>
#include <stdint.h>

/// Interleaves two 8-bit chroma planes into one CbCr plane (NV12's second plane).
/// `width` and `height` count chroma samples; strides are in bytes.
void pi_interleave_8(const uint8_t *cb, size_t cbStride,
                     const uint8_t *cr, size_t crStride,
                     uint8_t *dst, size_t dstStride,
                     size_t width, size_t height);

/// Interleaves two 16-bit chroma planes holding `bits`-bit values in their low bits into
/// one CbCr plane with the values in the high bits (P010 / P012's second plane).
void pi_interleave_16(const uint16_t *cb, size_t cbStride,
                      const uint16_t *cr, size_t crStride,
                      uint16_t *dst, size_t dstStride,
                      size_t width, size_t height, int bits);

/// Copies a 16-bit plane holding `bits`-bit values in their low bits, moving them to the
/// high bits (P010 / P012's luma plane).
void pi_shift_16(const uint16_t *src, size_t srcStride,
                 uint16_t *dst, size_t dstStride,
                 size_t width, size_t height, int bits);

/// Copies an 8-bit plane row by row.
void pi_copy_8(const uint8_t *src, size_t srcStride,
               uint8_t *dst, size_t dstStride,
               size_t width, size_t height);

#endif
