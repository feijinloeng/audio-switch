#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ypq_ring_buffer ypq_ring_buffer;

/// Creates a stereo Float32 SPSC buffer. Capacity is expressed in frames and
/// must be a non-zero power of two. Allocation is allowed only here.
ypq_ring_buffer *ypq_ring_buffer_create(uint32_t capacity_frames);
void ypq_ring_buffer_destroy(ypq_ring_buffer *buffer);

/// Producer-only and consumer-only respectively. They never allocate, lock,
/// log, or block; partial completion makes overflow/underflow observable.
uint32_t ypq_ring_buffer_write(
    ypq_ring_buffer *buffer,
    const float *interleaved_stereo_frames,
    uint32_t frame_count
);
uint32_t ypq_ring_buffer_read(
    ypq_ring_buffer *buffer,
    float *interleaved_stereo_frames,
    uint32_t frame_count
);

uint32_t ypq_ring_buffer_available_to_read(const ypq_ring_buffer *buffer);
uint32_t ypq_ring_buffer_available_to_write(const ypq_ring_buffer *buffer);

/// Control-plane-only tail disposal. Callers must prove both SPSC endpoints
/// are quiescent before using this; it is never callable from a callback.
uint32_t ypq_ring_buffer_discard_all(ypq_ring_buffer *buffer);

#ifdef __cplusplus
}
#endif
