#include "DeviceRenderSession.h"

#include "AdaptiveASRC.h"
#include "ClockDomainBridge.h"
#include "RealtimeBusLimiter.h"
#include "RealtimeMixer.h"

#include <algorithm>
#include <cstring>
#include <atomic>
#include <chrono>
#include <limits>
#include <mach/mach_time.h>
#include <new>
#include <thread>
#include <vector>

namespace { constexpr uint32_t kChannels = 2; }

struct route_state {
    ypq_route_binding *binding;
    ypq_adaptive_asrc *asrc;
    ypq_clock_bridge *clock;
    std::vector<float> scratch;
    bool has_reached_pre_roll {false};
    bool recovering {false};
    float current_gain {1.0F};
    float last_output_left {0.0F};
    float last_output_right {0.0F};
};

struct ypq_device_render_session {
    uint32_t binding_capacity_frames;
    uint32_t max_callback_frames;
    double target_nominal_rate;
    uint32_t pre_roll_frames;
    uint32_t target_fill_frames;
    uint32_t low_frames;
    uint32_t high_frames;
    ypq_bus_limiter *bus_limiter;
    std::vector<route_state> routes;
    std::vector<const float *> sources;
    std::vector<float> gains;
    std::vector<float> delay_history;
    std::vector<float> delay_prime_scratch;
    uint32_t delay_capacity_frames {0};
    uint32_t maximum_delay_frames {0};
    uint32_t delay_transition_frames {1};
    uint64_t delay_write_frame {0};
    uint32_t delay_history_frames {0};
    uint32_t current_delay_frames {0};
    uint32_t transition_from_delay_frames {0};
    uint32_t transition_to_delay_frames {0};
    uint32_t transition_position {0};
    bool delay_transition_active {false};
    std::atomic<uint32_t> target_delay_frames {0};
    std::atomic<uint32_t> published_delay_frames {0};
    std::atomic<uint64_t> render_callback_count {0};
    std::atomic<uint64_t> maximum_render_ticks {0};
    std::atomic<uint64_t> last_render_host_ticks {0};
    std::atomic<uint32_t> maximum_callback_frames_seen {0};
    std::atomic<uint64_t> low_watermark_event_count {0};
    std::atomic<uint64_t> recovery_event_count {0};
    std::atomic<uint64_t> partial_underrun_frames {0};
    std::atomic<uint32_t> minimum_effective_fill_frames {UINT32_MAX};
    std::atomic<uint32_t> maximum_effective_fill_frames {0};
};

struct ypq_device_render_host {
    std::atomic<ypq_device_render_session *> session;
    // High bit means replacement/teardown is closing admissions; all lower
    // bits count callbacks that already obtained the current snapshot.
    std::atomic<uint64_t> gate_word {0};
    std::atomic<uint64_t> last_callback_sample_time_bits {0};
    std::atomic<uint64_t> last_callback_host_time {0};
};

namespace {

constexpr float kGainRampCoefficient = 0.0007F;

float delayed_sample(
    const ypq_device_render_session *session,
    uint64_t write_frame,
    uint32_t delay_frames,
    uint32_t channel
) {
    const uint64_t read_frame = write_frame - delay_frames;
    const size_t index = static_cast<size_t>(
        read_frame % session->delay_capacity_frames
    ) * kChannels + channel;
    return session->delay_history[index];
}

void process_device_delay(
    ypq_device_render_session *session,
    float *output,
    uint32_t frame_count
) {
    if (session->delay_capacity_frames == 0) return;
    for (uint32_t frame = 0; frame < frame_count; ++frame) {
        const uint64_t write_frame = session->delay_write_frame;
        const size_t history_index = static_cast<size_t>(
            write_frame % session->delay_capacity_frames
        ) * kChannels;
        const size_t output_index = static_cast<size_t>(frame) * kChannels;
        session->delay_history[history_index] = output[output_index];
        session->delay_history[history_index + 1] = output[output_index + 1];
        session->delay_history_frames = std::min(
            session->maximum_delay_frames + 1,
            session->delay_history_frames + 1
        );

        const uint32_t requested = std::min(
            session->target_delay_frames.load(std::memory_order_acquire),
            session->maximum_delay_frames
        );
        if (!session->delay_transition_active
            && requested != session->current_delay_frames
            && requested < session->delay_history_frames) {
            session->transition_from_delay_frames = session->current_delay_frames;
            session->transition_to_delay_frames = requested;
            session->transition_position = 0;
            session->delay_transition_active = true;
        }

        if (session->delay_transition_active) {
            const float alpha = std::min(
                1.0F,
                static_cast<float>(session->transition_position + 1)
                    / static_cast<float>(session->delay_transition_frames)
            );
            for (uint32_t channel = 0; channel < kChannels; ++channel) {
                const float from = delayed_sample(
                    session, write_frame, session->transition_from_delay_frames, channel
                );
                const float to = delayed_sample(
                    session, write_frame, session->transition_to_delay_frames, channel
                );
                output[output_index + channel] = from + (to - from) * alpha;
            }
            ++session->transition_position;
            if (session->transition_position >= session->delay_transition_frames) {
                session->current_delay_frames = session->transition_to_delay_frames;
                session->published_delay_frames.store(
                    session->current_delay_frames,
                    std::memory_order_release
                );
                session->delay_transition_active = false;
            }
        } else {
            for (uint32_t channel = 0; channel < kChannels; ++channel) {
                output[output_index + channel] = delayed_sample(
                    session, write_frame, session->current_delay_frames, channel
                );
            }
        }
        ++session->delay_write_frame;
    }
}

void apply_binding_controls(route_state &route, uint32_t frame_count) {
    const bool muted = ypq_route_binding_published_muted(route.binding);
    const float target_gain = muted ? 0.0F : ypq_route_binding_published_gain(route.binding);
    const size_t sample_count = static_cast<size_t>(frame_count) * kChannels;
    for (size_t index = 0; index < sample_count; ++index) {
        route.current_gain += (target_gain - route.current_gain) * kGainRampCoefficient;
        route.scratch[index] *= route.current_gain;
    }
}

uint32_t effective_fill_frames(const route_state &route) {
    const uint64_t total = static_cast<uint64_t>(ypq_route_binding_available_frames(route.binding))
        + ypq_adaptive_asrc_pending_frames(route.asrc);
    return static_cast<uint32_t>(std::min<uint64_t>(total, UINT32_MAX));
}

void begin_starvation_recovery(route_state &route) {
    if (route.has_reached_pre_roll) {
        ypq_adaptive_asrc_reset(route.asrc);
        ypq_clock_bridge_reset(route.clock);
        route.current_gain = 0.0F;
    }
    route.has_reached_pre_roll = false;
    route.recovering = true;
}

void remember_last_output(route_state &route, uint32_t frame_count) {
    if (frame_count == 0) return;
    const size_t last = static_cast<size_t>(frame_count - 1) * kChannels;
    route.last_output_left = route.scratch[last];
    route.last_output_right = route.scratch[last + 1];
}

void remember_silence(route_state &route) {
    route.last_output_left = 0.0F;
    route.last_output_right = 0.0F;
}

void ramp_starvation_tail(route_state &route, uint32_t produced, uint32_t frame_count) {
    if (produced >= frame_count) return;
    float left = route.last_output_left;
    float right = route.last_output_right;
    if (produced > 0) {
        const size_t last_produced = static_cast<size_t>(produced - 1) * kChannels;
        left = route.scratch[last_produced];
        right = route.scratch[last_produced + 1];
    }
    const uint32_t tail_frames = frame_count - produced;
    for (uint32_t frame = 0; frame < tail_frames; ++frame) {
        const float gain = 1.0F - (
            static_cast<float>(frame + 1) / static_cast<float>(tail_frames)
        );
        const size_t sample = static_cast<size_t>(produced + frame) * kChannels;
        route.scratch[sample] = left * gain;
        route.scratch[sample + 1] = right * gain;
    }
}

constexpr uint64_t kClosingMask = UINT64_C(1) << 63;
constexpr uint64_t kCountMask = ~kClosingMask;

template <typename Value>
void publish_max(std::atomic<Value> &target, Value candidate) {
    Value observed = target.load(std::memory_order_relaxed);
    while (observed < candidate
           && !target.compare_exchange_weak(
               observed, candidate, std::memory_order_release, std::memory_order_relaxed
           )) {
    }
}

template <typename Value>
void publish_min(std::atomic<Value> &target, Value candidate) {
    Value observed = target.load(std::memory_order_relaxed);
    while (observed > candidate
           && !target.compare_exchange_weak(
               observed, candidate, std::memory_order_release, std::memory_order_relaxed
           )) {
    }
}

uint64_t double_bits(double value) {
    uint64_t bits = 0;
    static_assert(sizeof(bits) == sizeof(value));
    std::memcpy(&bits, &value, sizeof(bits));
    return bits;
}

double bits_double(uint64_t bits) {
    double value = 0;
    static_assert(sizeof(bits) == sizeof(value));
    std::memcpy(&value, &bits, sizeof(value));
    return value;
}

bool host_try_enter(ypq_device_render_host *host) {
    uint64_t observed = host->gate_word.load(std::memory_order_acquire);
    while ((observed & kClosingMask) == 0) {
        const uint64_t count = observed & kCountMask;
        if (count == kCountMask) return false;
        if (host->gate_word.compare_exchange_weak(
                observed,
                observed + 1,
                std::memory_order_acq_rel,
                std::memory_order_acquire
            )) {
            return true;
        }
    }
    return false;
}

void host_leave(ypq_device_render_host *host) {
    host->gate_word.fetch_sub(1, std::memory_order_release);
}

bool host_begin_closing(ypq_device_render_host *host) {
    uint64_t observed = host->gate_word.load(std::memory_order_acquire);
    while ((observed & kClosingMask) == 0) {
        if (host->gate_word.compare_exchange_weak(
                observed,
                observed | kClosingMask,
                std::memory_order_acq_rel,
                std::memory_order_acquire
            )) {
            return true;
        }
    }
    return false;
}

bool can_retain_route_state(
    const ypq_device_render_session *prior,
    const ypq_device_render_session *replacement
) {
    return prior->binding_capacity_frames == replacement->binding_capacity_frames
        && prior->max_callback_frames == replacement->max_callback_frames
        && prior->target_nominal_rate == replacement->target_nominal_rate
        && prior->pre_roll_frames == replacement->pre_roll_frames
        && prior->target_fill_frames == replacement->target_fill_frames
        && prior->low_frames == replacement->low_frames
        && prior->high_frames == replacement->high_frames;
}

void retain_unchanged_route_state(
    ypq_device_render_session *prior,
    ypq_device_render_session *replacement
) {
    if (!can_retain_route_state(prior, replacement)) return;
    for (auto &replacement_route : replacement->routes) {
        const auto prior_route = std::find_if(
            prior->routes.begin(),
            prior->routes.end(),
            [&replacement_route](const route_state &candidate) {
                return candidate.binding == replacement_route.binding;
            }
        );
        if (prior_route != prior->routes.end()) {
            std::swap(replacement_route, *prior_route);
        }
    }
}

bool host_wait_for_quiescence(ypq_device_render_host *host, uint64_t timeout_microseconds) {
    const auto deadline = std::chrono::steady_clock::now()
        + std::chrono::microseconds(timeout_microseconds);
    while (host->gate_word.load(std::memory_order_acquire) != kClosingMask) {
        if (std::chrono::steady_clock::now() >= deadline) return false;
        std::this_thread::yield();
    }
    return true;
}

void host_reopen(ypq_device_render_host *host) {
    uint64_t observed = host->gate_word.load(std::memory_order_acquire);
    while ((observed & kClosingMask) != 0) {
        const uint64_t reopened = observed & kCountMask;
        if (host->gate_word.compare_exchange_weak(
                observed,
                reopened,
                std::memory_order_release,
                std::memory_order_acquire
            )) {
            return;
        }
    }
}

} // namespace

namespace {

ypq_device_render_session *create_session(
    ypq_route_binding *const *bindings,
    uint32_t binding_count,
    uint32_t binding_capacity_frames,
    uint32_t max_callback_frames,
    double target_nominal_rate,
    uint32_t target_fill_frames,
    uint32_t pre_roll_frames,
    uint32_t low_frames,
    uint32_t high_frames
) {
    if (bindings == nullptr || binding_count == 0 || binding_capacity_frames == 0
        || max_callback_frames == 0 || target_fill_frames == 0
        || pre_roll_frames > binding_capacity_frames
        || low_frames > target_fill_frames
        || target_fill_frames > high_frames
        || high_frames > binding_capacity_frames) return nullptr;
    auto *limiter = ypq_bus_limiter_create(static_cast<float>(target_nominal_rate), 0.944F, 12.0F);
    if (limiter == nullptr) return nullptr;
    auto *session = new (std::nothrow) ypq_device_render_session {};
    if (session == nullptr) {
        ypq_bus_limiter_destroy(limiter);
        return nullptr;
    }
    session->binding_capacity_frames = binding_capacity_frames;
    session->max_callback_frames = max_callback_frames;
    session->target_nominal_rate = target_nominal_rate;
    session->pre_roll_frames = pre_roll_frames;
    session->target_fill_frames = target_fill_frames;
    session->low_frames = low_frames;
    session->high_frames = high_frames;
    session->bus_limiter = limiter;
    try {
        session->routes.reserve(binding_count);
        session->sources.resize(binding_count);
        session->gains.assign(binding_count, 1.0F);
        for (uint32_t index = 0; index < binding_count; ++index) {
            if (bindings[index] == nullptr) throw 0;
            auto *asrc = ypq_adaptive_asrc_create(binding_capacity_frames);
            auto *clock = ypq_clock_bridge_create(target_nominal_rate, target_fill_frames, 0.05, 0.001);
            if (asrc == nullptr || clock == nullptr) {
                ypq_adaptive_asrc_destroy(asrc);
                ypq_clock_bridge_destroy(clock);
                throw 0;
            }
            session->routes.push_back({bindings[index], asrc, clock,
                std::vector<float>(static_cast<size_t>(max_callback_frames) * kChannels), false, false, 1.0F});
        }
    } catch (...) {
        ypq_device_render_session_destroy(session);
        return nullptr;
    }
    return session;
}

} // namespace

ypq_device_render_session *ypq_device_render_session_create(
    ypq_route_binding *const *bindings,
    uint32_t binding_count,
    uint32_t binding_capacity_frames,
    uint32_t max_callback_frames,
    double target_nominal_rate,
    uint32_t target_fill_frames,
    uint32_t pre_roll_frames
) {
    return create_session(
        bindings,
        binding_count,
        binding_capacity_frames,
        max_callback_frames,
        target_nominal_rate,
        target_fill_frames,
        pre_roll_frames,
        std::min(pre_roll_frames, target_fill_frames),
        binding_capacity_frames
    );
}

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
) {
    return create_session(
        bindings,
        binding_count,
        binding_capacity_frames,
        max_callback_frames,
        target_nominal_rate,
        target_fill_frames,
        pre_roll_frames,
        low_frames,
        high_frames
    );
}

void ypq_device_render_session_destroy(ypq_device_render_session *session) {
    if (session == nullptr) return;
    for (auto &route : session->routes) {
        ypq_adaptive_asrc_destroy(route.asrc);
        ypq_clock_bridge_destroy(route.clock);
    }
    ypq_bus_limiter_destroy(session->bus_limiter);
    delete session;
}

void ypq_device_render_session_render(
    ypq_device_render_session *session,
    float *output,
    uint32_t frame_count
) {
    const uint64_t started_at = mach_absolute_time();
    if (output == nullptr || frame_count == 0) return;
    if (session == nullptr || frame_count > session->max_callback_frames) {
        std::memset(output, 0, static_cast<size_t>(frame_count) * kChannels * sizeof(float));
        return;
    }
    for (uint32_t index = 0; index < session->routes.size(); ++index) {
        auto &route = session->routes[index];
        const uint32_t fill = effective_fill_frames(route);
        publish_min(session->minimum_effective_fill_frames, fill);
        publish_max(session->maximum_effective_fill_frames, fill);
        if (route.has_reached_pre_roll && fill < session->low_frames) {
            session->low_watermark_event_count.fetch_add(1, std::memory_order_relaxed);
            route.recovering = true;
        }
        if (!route.has_reached_pre_roll && fill < session->pre_roll_frames) {
            std::memset(route.scratch.data(), 0,
                static_cast<size_t>(frame_count) * kChannels * sizeof(float));
            remember_silence(route);
            session->sources[index] = route.scratch.data();
            continue;
        }
        route.has_reached_pre_roll = true;
        const double ratio = ypq_clock_bridge_update_for_frames(
            route.clock, fill, route.recovering || fill > session->high_frames, frame_count
        );
        const uint32_t produced = ypq_adaptive_asrc_process(
            route.asrc, route.binding, route.scratch.data(), frame_count, ratio
        );
        const uint32_t remaining_fill = effective_fill_frames(route);
        if (produced < frame_count) {
            session->partial_underrun_frames.fetch_add(
                frame_count - produced,
                std::memory_order_relaxed
            );
            ramp_starvation_tail(route, produced, frame_count);
        }
        apply_binding_controls(route, frame_count);
        remember_last_output(route, frame_count);
        // libsamplerate can intentionally yield fewer frames while retaining
        // input in its own pending buffer (notably during filter warm-up).
        // That is not a source starvation and must not discard the pending
        // frames by rearming pre-roll.
        if (produced < frame_count && remaining_fill == 0) {
            session->recovery_event_count.fetch_add(1, std::memory_order_relaxed);
            begin_starvation_recovery(route);
            remember_silence(route);
        } else if (route.recovering && remaining_fill >= session->target_fill_frames) {
            route.recovering = false;
        }
        session->sources[index] = route.scratch.data();
    }
    ypq_realtime_mixer_mix(session->sources.data(), session->gains.data(),
        static_cast<uint32_t>(session->routes.size()), output, frame_count);
    ypq_bus_limiter_process(session->bus_limiter, output, frame_count);
    process_device_delay(session, output, frame_count);
    session->render_callback_count.fetch_add(1, std::memory_order_relaxed);
    session->last_render_host_ticks.store(started_at, std::memory_order_release);
    publish_max(session->maximum_callback_frames_seen, frame_count);
    publish_max(session->maximum_render_ticks, mach_absolute_time() - started_at);
}

bool ypq_device_render_session_configure_delay(
    ypq_device_render_session *session,
    uint32_t maximum_delay_frames,
    uint32_t initial_delay_frames,
    uint32_t transition_frames
) {
    if (session == nullptr || maximum_delay_frames == 0
        || maximum_delay_frames >= UINT32_MAX - session->max_callback_frames
        || initial_delay_frames > maximum_delay_frames) return false;
    try {
        session->delay_capacity_frames = maximum_delay_frames
            + session->max_callback_frames + 1;
        session->delay_history.assign(
            static_cast<size_t>(session->delay_capacity_frames) * kChannels,
            0.0F
        );
        session->delay_prime_scratch.assign(
            static_cast<size_t>(session->max_callback_frames) * kChannels,
            0.0F
        );
    } catch (...) {
        session->delay_history.clear();
        session->delay_prime_scratch.clear();
        session->delay_capacity_frames = 0;
        return false;
    }
    session->maximum_delay_frames = maximum_delay_frames;
    session->delay_transition_frames = std::max(1U, transition_frames);
    session->delay_write_frame = 0;
    session->delay_history_frames = 0;
    session->current_delay_frames = initial_delay_frames;
    session->transition_from_delay_frames = initial_delay_frames;
    session->transition_to_delay_frames = initial_delay_frames;
    session->transition_position = 0;
    session->delay_transition_active = false;
    session->target_delay_frames.store(initial_delay_frames, std::memory_order_release);
    session->published_delay_frames.store(initial_delay_frames, std::memory_order_release);
    return true;
}

bool ypq_device_render_session_prime_delay(
    ypq_device_render_session *session,
    uint32_t frame_count
) {
    if (session == nullptr || session->delay_capacity_frames == 0
        || frame_count > session->maximum_delay_frames) return false;
    uint32_t remaining = frame_count;
    while (remaining > 0) {
        const uint32_t chunk = std::min(remaining, session->max_callback_frames);
        ypq_device_render_session_render(session, session->delay_prime_scratch.data(), chunk);
        remaining -= chunk;
    }
    // Offline priming is not an AUHAL callback and must not satisfy runtime
    // heartbeat/health checks before the device has actually started.
    session->render_callback_count.store(0, std::memory_order_relaxed);
    session->maximum_render_ticks.store(0, std::memory_order_relaxed);
    session->last_render_host_ticks.store(0, std::memory_order_relaxed);
    session->maximum_callback_frames_seen.store(0, std::memory_order_relaxed);
    session->low_watermark_event_count.store(0, std::memory_order_relaxed);
    session->recovery_event_count.store(0, std::memory_order_relaxed);
    session->partial_underrun_frames.store(0, std::memory_order_relaxed);
    session->minimum_effective_fill_frames.store(UINT32_MAX, std::memory_order_relaxed);
    session->maximum_effective_fill_frames.store(0, std::memory_order_relaxed);
    return true;
}

void ypq_device_render_session_set_delay_frames(
    ypq_device_render_session *session,
    uint32_t delay_frames
) {
    if (session == nullptr || session->delay_capacity_frames == 0) return;
    session->target_delay_frames.store(
        std::min(delay_frames, session->maximum_delay_frames),
        std::memory_order_release
    );
}

uint32_t ypq_device_render_session_current_delay_frames(
    const ypq_device_render_session *session
) {
    return session == nullptr ? 0
        : session->published_delay_frames.load(std::memory_order_acquire);
}

uint64_t ypq_device_render_session_render_callback_count(
    const ypq_device_render_session *session
) {
    return session == nullptr ? 0 : session->render_callback_count.load(std::memory_order_acquire);
}

uint64_t ypq_device_render_session_maximum_render_ticks(
    const ypq_device_render_session *session
) {
    return session == nullptr ? 0 : session->maximum_render_ticks.load(std::memory_order_acquire);
}

uint64_t ypq_device_render_session_last_render_host_ticks(
    const ypq_device_render_session *session
) {
    return session == nullptr ? 0 : session->last_render_host_ticks.load(std::memory_order_acquire);
}

uint32_t ypq_device_render_session_maximum_callback_frames(
    const ypq_device_render_session *session
) {
    return session == nullptr ? 0 : session->maximum_callback_frames_seen.load(std::memory_order_acquire);
}

uint64_t ypq_device_render_session_low_watermark_event_count(
    const ypq_device_render_session *session
) {
    return session == nullptr ? 0 : session->low_watermark_event_count.load(std::memory_order_acquire);
}

uint64_t ypq_device_render_session_recovery_event_count(
    const ypq_device_render_session *session
) {
    return session == nullptr ? 0 : session->recovery_event_count.load(std::memory_order_acquire);
}

uint64_t ypq_device_render_session_partial_underrun_frames(
    const ypq_device_render_session *session
) {
    return session == nullptr ? 0 : session->partial_underrun_frames.load(std::memory_order_acquire);
}

uint32_t ypq_device_render_session_minimum_effective_fill_frames(
    const ypq_device_render_session *session
) {
    if (session == nullptr) return 0;
    const uint32_t frames = session->minimum_effective_fill_frames.load(std::memory_order_acquire);
    return frames == UINT32_MAX ? 0 : frames;
}

uint32_t ypq_device_render_session_maximum_effective_fill_frames(
    const ypq_device_render_session *session
) {
    return session == nullptr
        ? 0
        : session->maximum_effective_fill_frames.load(std::memory_order_acquire);
}

void ypq_device_render_session_acknowledge_snapshot_removal(
    ypq_device_render_session *session,
    uint64_t snapshot_generation
) {
    if (session == nullptr) return;
    for (auto &route : session->routes) {
        ypq_route_binding_acknowledge_snapshot_removal(route.binding, snapshot_generation);
    }
}

bool ypq_device_render_session_ready_to_reclaim(
    const ypq_device_render_session *session,
    uint64_t required_snapshot_generation
) {
    if (session == nullptr) return false;
    for (const auto &route : session->routes) {
        if (!ypq_route_binding_ready_to_reclaim(route.binding, required_snapshot_generation)) {
            return false;
        }
    }
    return true;
}

bool ypq_device_render_session_finish_retirement(ypq_device_render_session *session) {
    if (session == nullptr) return false;
    bool finished = true;
    for (auto &route : session->routes) {
        finished = ypq_route_binding_finish_retirement(route.binding) && finished;
    }
    return finished;
}

ypq_device_render_host *ypq_device_render_host_create(ypq_device_render_session *initial) {
    if (initial == nullptr) return nullptr;
    auto *host = new (std::nothrow) ypq_device_render_host {initial, 0, 0, 0};
    return host;
}

void ypq_device_render_host_destroy(ypq_device_render_host *host) {
    if (host == nullptr) return;
    if (!host_begin_closing(host)) return;
    while (host->gate_word.load(std::memory_order_acquire) != kClosingMask) {
        std::this_thread::yield();
    }
    ypq_device_render_session_destroy(host->session.exchange(nullptr, std::memory_order_acq_rel));
    delete host;
}

void ypq_device_render_host_render(
    ypq_device_render_host *host,
    float *interleaved_stereo_output,
    uint32_t frame_count
) {
    if (host == nullptr || !host_try_enter(host)) {
        if (interleaved_stereo_output != nullptr) {
            std::memset(
                interleaved_stereo_output,
                0,
                static_cast<size_t>(frame_count) * kChannels * sizeof(float)
            );
        }
        return;
    }
    auto *session = host->session.load(std::memory_order_acquire);
    ypq_device_render_session_render(session, interleaved_stereo_output, frame_count);
    host_leave(host);
}

void ypq_device_render_host_set_delay_frames(
    ypq_device_render_host *host,
    uint32_t delay_frames
) {
    if (host == nullptr || !host_try_enter(host)) return;
    ypq_device_render_session_set_delay_frames(
        host->session.load(std::memory_order_acquire),
        delay_frames
    );
    host_leave(host);
}

void ypq_device_render_host_set_initial_gain(
    ypq_device_render_host *host,
    float gain
) {
    if (host == nullptr || !host_try_enter(host)) return;
    auto *session = host->session.load(std::memory_order_acquire);
    if (session != nullptr) {
        // NaN and out-of-range values clamp to 0 so a joining endpoint starts
        // silent. The render callback later ramps current_gain toward whatever
        // target the control plane publishes.
        float normalized = gain;
        if (!(normalized >= 0.0F && normalized <= 1.0F)) normalized = 0.0F;
        for (auto &route : session->routes) {
            route.current_gain = normalized;
        }
    }
    host_leave(host);
}

bool ypq_device_render_host_replace(
    ypq_device_render_host *host,
    ypq_device_render_session *replacement,
    uint64_t timeout_microseconds
) {
    if (host == nullptr || replacement == nullptr || !host_begin_closing(host)) return false;
    if (!host_wait_for_quiescence(host, timeout_microseconds)) {
        host_reopen(host);
        return false;
    }
    auto *prior = host->session.exchange(replacement, std::memory_order_acq_rel);
    retain_unchanged_route_state(prior, replacement);
    host->gate_word.store(0, std::memory_order_release);
    ypq_device_render_session_destroy(prior);
    return true;
}

uint64_t ypq_device_render_host_render_callback_count(const ypq_device_render_host *host) {
    auto *mutable_host = const_cast<ypq_device_render_host *>(host);
    if (mutable_host == nullptr || !host_try_enter(mutable_host)) return 0;
    const auto result = ypq_device_render_session_render_callback_count(
        mutable_host->session.load(std::memory_order_acquire)
    );
    host_leave(mutable_host);
    return result;
}

uint64_t ypq_device_render_host_maximum_render_ticks(const ypq_device_render_host *host) {
    auto *mutable_host = const_cast<ypq_device_render_host *>(host);
    if (mutable_host == nullptr || !host_try_enter(mutable_host)) return 0;
    const auto result = ypq_device_render_session_maximum_render_ticks(
        mutable_host->session.load(std::memory_order_acquire)
    );
    host_leave(mutable_host);
    return result;
}

uint64_t ypq_device_render_host_last_render_host_ticks(const ypq_device_render_host *host) {
    auto *mutable_host = const_cast<ypq_device_render_host *>(host);
    if (mutable_host == nullptr || !host_try_enter(mutable_host)) return 0;
    const auto result = ypq_device_render_session_last_render_host_ticks(
        mutable_host->session.load(std::memory_order_acquire)
    );
    host_leave(mutable_host);
    return result;
}

uint32_t ypq_device_render_host_maximum_callback_frames(const ypq_device_render_host *host) {
    auto *mutable_host = const_cast<ypq_device_render_host *>(host);
    if (mutable_host == nullptr || !host_try_enter(mutable_host)) return 0;
    const auto result = ypq_device_render_session_maximum_callback_frames(
        mutable_host->session.load(std::memory_order_acquire)
    );
    host_leave(mutable_host);
    return result;
}

uint64_t ypq_device_render_host_low_watermark_event_count(const ypq_device_render_host *host) {
    auto *mutable_host = const_cast<ypq_device_render_host *>(host);
    if (mutable_host == nullptr || !host_try_enter(mutable_host)) return 0;
    const auto result = ypq_device_render_session_low_watermark_event_count(
        mutable_host->session.load(std::memory_order_acquire)
    );
    host_leave(mutable_host);
    return result;
}

uint64_t ypq_device_render_host_recovery_event_count(const ypq_device_render_host *host) {
    auto *mutable_host = const_cast<ypq_device_render_host *>(host);
    if (mutable_host == nullptr || !host_try_enter(mutable_host)) return 0;
    const auto result = ypq_device_render_session_recovery_event_count(
        mutable_host->session.load(std::memory_order_acquire)
    );
    host_leave(mutable_host);
    return result;
}

uint64_t ypq_device_render_host_partial_underrun_frames(const ypq_device_render_host *host) {
    auto *mutable_host = const_cast<ypq_device_render_host *>(host);
    if (mutable_host == nullptr || !host_try_enter(mutable_host)) return 0;
    const auto result = ypq_device_render_session_partial_underrun_frames(
        mutable_host->session.load(std::memory_order_acquire)
    );
    host_leave(mutable_host);
    return result;
}

uint32_t ypq_device_render_host_minimum_effective_fill_frames(const ypq_device_render_host *host) {
    auto *mutable_host = const_cast<ypq_device_render_host *>(host);
    if (mutable_host == nullptr || !host_try_enter(mutable_host)) return 0;
    const auto result = ypq_device_render_session_minimum_effective_fill_frames(
        mutable_host->session.load(std::memory_order_acquire)
    );
    host_leave(mutable_host);
    return result;
}

uint32_t ypq_device_render_host_maximum_effective_fill_frames(const ypq_device_render_host *host) {
    auto *mutable_host = const_cast<ypq_device_render_host *>(host);
    if (mutable_host == nullptr || !host_try_enter(mutable_host)) return 0;
    const auto result = ypq_device_render_session_maximum_effective_fill_frames(
        mutable_host->session.load(std::memory_order_acquire)
    );
    host_leave(mutable_host);
    return result;
}

void ypq_device_render_host_record_callback_timestamp(
    ypq_device_render_host *host,
    double sample_time,
    uint64_t host_time
) {
    if (host == nullptr) return;
    host->last_callback_sample_time_bits.store(double_bits(sample_time), std::memory_order_relaxed);
    host->last_callback_host_time.store(host_time, std::memory_order_relaxed);
}

double ypq_device_render_host_last_callback_sample_time(const ypq_device_render_host *host) {
    auto *mutable_host = const_cast<ypq_device_render_host *>(host);
    if (mutable_host == nullptr || !host_try_enter(mutable_host)) return 0;
    const auto result = bits_double(
        mutable_host->last_callback_sample_time_bits.load(std::memory_order_acquire)
    );
    host_leave(mutable_host);
    return result;
}

uint64_t ypq_device_render_host_last_callback_host_time(const ypq_device_render_host *host) {
    auto *mutable_host = const_cast<ypq_device_render_host *>(host);
    if (mutable_host == nullptr || !host_try_enter(mutable_host)) return 0;
    const auto result = mutable_host->last_callback_host_time.load(std::memory_order_acquire);
    host_leave(mutable_host);
    return result;
}

void ypq_device_render_host_acknowledge_snapshot_removal(
    ypq_device_render_host *host,
    uint64_t snapshot_generation
) {
    if (host == nullptr || !host_try_enter(host)) return;
    ypq_device_render_session_acknowledge_snapshot_removal(
        host->session.load(std::memory_order_acquire),
        snapshot_generation
    );
    host_leave(host);
}
