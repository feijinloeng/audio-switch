#pragma once

#include <stdint.h>

#include "RouteBinding.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ypq_device_render_session ypq_device_render_session;
typedef struct ypq_device_render_host ypq_device_render_host;

/// Prepares independent ASRC state and PCM scratch for every active binding
/// targeting one physical output. All arguments are fixed for this snapshot.
ypq_device_render_session *ypq_device_render_session_create(
    ypq_route_binding *const *bindings,
    uint32_t binding_count,
    uint32_t binding_capacity_frames,
    uint32_t max_callback_frames,
    double target_nominal_rate,
    uint32_t target_fill_frames,
    uint32_t pre_roll_frames
);
/// Creates a session with the complete immutable buffer-watermark profile.
/// `low_frames` rearms pre-roll after a starvation; `high_frames` marks a
/// fill excursion that needs recovery-rate clock correction.
ypq_device_render_session *ypq_device_render_session_create_with_watermarks(
    ypq_route_binding *const *bindings,
    uint32_t binding_count,
    uint32_t binding_capacity_frames,
    uint32_t max_callback_frames,
    double target_nominal_rate,
    uint32_t target_fill_frames,
    uint32_t pre_roll_frames,
    uint32_t low_frames,
    uint32_t high_frames
);
void ypq_device_render_session_destroy(ypq_device_render_session *session);

/// Renders every prepared binding, then mixes to one interleaved stereo bus.
/// This callback operation never allocates, locks, logs, or blocks.
void ypq_device_render_session_render(
    ypq_device_render_session *session,
    float *interleaved_stereo_output,
    uint32_t frame_count
);

/// Allocates a device-bus delay line on the control plane. Call before the
/// session enters a render host. The render callback only reads/writes this
/// preallocated storage and observes target changes through one atomic.
bool ypq_device_render_session_configure_delay(
    ypq_device_render_session *session,
    uint32_t maximum_delay_frames,
    uint32_t initial_delay_frames,
    uint32_t transition_frames
);

/// Primes the configured delay history from already pre-rolled bindings while
/// discarding the generated output. This is a control-plane startup operation.
bool ypq_device_render_session_prime_delay(
    ypq_device_render_session *session,
    uint32_t frame_count
);

/// Publishes an absolute delay target without rebuilding the render snapshot.
void ypq_device_render_session_set_delay_frames(
    ypq_device_render_session *session,
    uint32_t delay_frames
);

uint32_t ypq_device_render_session_current_delay_frames(
    const ypq_device_render_session *session
);

/// Callback-path observability for the development hardware harness. Values
/// are monotonic atomics; reading them never mutates realtime state. Ticks
/// use `mach_absolute_time()` and are converted to time off the callback.
uint64_t ypq_device_render_session_render_callback_count(
    const ypq_device_render_session *session
);
uint64_t ypq_device_render_session_maximum_render_ticks(
    const ypq_device_render_session *session
);
uint64_t ypq_device_render_session_last_render_host_ticks(
    const ypq_device_render_session *session
);
uint32_t ypq_device_render_session_maximum_callback_frames(
    const ypq_device_render_session *session
);
uint64_t ypq_device_render_session_low_watermark_event_count(
    const ypq_device_render_session *session
);
uint64_t ypq_device_render_session_recovery_event_count(
    const ypq_device_render_session *session
);
uint64_t ypq_device_render_session_partial_underrun_frames(
    const ypq_device_render_session *session
);
uint32_t ypq_device_render_session_minimum_effective_fill_frames(
    const ypq_device_render_session *session
);
uint32_t ypq_device_render_session_maximum_effective_fill_frames(
    const ypq_device_render_session *session
);

/// Marks this render snapshot absent from the output callback. Binding memory
/// remains owned by the control plane until every producer/tail/gate proof is
/// complete; this function never destroys a binding.
void ypq_device_render_session_acknowledge_snapshot_removal(
    ypq_device_render_session *session,
    uint64_t snapshot_generation
);
bool ypq_device_render_session_ready_to_reclaim(
    const ypq_device_render_session *session,
    uint64_t required_snapshot_generation
);
bool ypq_device_render_session_finish_retirement(ypq_device_render_session *session);

/// Long-lived callback owner for an output device. It switches prepared
/// render snapshots only after every old callback has left its one-word gate;
/// the callback itself performs no allocation, locking, or lifecycle work.
/// On a successful replace, ownership of `replacement` transfers to `host`.
ypq_device_render_host *ypq_device_render_host_create(ypq_device_render_session *initial);
void ypq_device_render_host_destroy(ypq_device_render_host *host);
void ypq_device_render_host_render(
    ypq_device_render_host *host,
    float *interleaved_stereo_output,
    uint32_t frame_count
);

/// Control-plane publication to the active immutable render snapshot.
void ypq_device_render_host_set_delay_frames(
    ypq_device_render_host *host,
    uint32_t delay_frames
);

/// Sets the initial per-binding gain of the active render snapshot before any
/// callback has rendered. Used by endpoint hot-swap to start a joining speaker
/// silent so its audio can fade in from zero.
void ypq_device_render_host_set_initial_gain(
    ypq_device_render_host *host,
    float gain
);
bool ypq_device_render_host_replace(
    ypq_device_render_host *host,
    ypq_device_render_session *replacement,
    uint64_t timeout_microseconds
);
uint64_t ypq_device_render_host_render_callback_count(const ypq_device_render_host *host);
uint64_t ypq_device_render_host_maximum_render_ticks(const ypq_device_render_host *host);
uint64_t ypq_device_render_host_last_render_host_ticks(const ypq_device_render_host *host);
uint32_t ypq_device_render_host_maximum_callback_frames(const ypq_device_render_host *host);
uint64_t ypq_device_render_host_low_watermark_event_count(const ypq_device_render_host *host);
uint64_t ypq_device_render_host_recovery_event_count(const ypq_device_render_host *host);
uint64_t ypq_device_render_host_partial_underrun_frames(const ypq_device_render_host *host);
uint32_t ypq_device_render_host_minimum_effective_fill_frames(const ypq_device_render_host *host);
uint32_t ypq_device_render_host_maximum_effective_fill_frames(const ypq_device_render_host *host);
/// The AUHAL callback records its incoming AudioTimeStamp with atomic stores
/// before rendering. These values are diagnostics, not clock-control inputs.
void ypq_device_render_host_record_callback_timestamp(
    ypq_device_render_host *host,
    double sample_time,
    uint64_t host_time
);
double ypq_device_render_host_last_callback_sample_time(const ypq_device_render_host *host);
uint64_t ypq_device_render_host_last_callback_host_time(const ypq_device_render_host *host);
void ypq_device_render_host_acknowledge_snapshot_removal(
    ypq_device_render_host *host,
    uint64_t snapshot_generation
);

#ifdef __cplusplus
}
#endif
