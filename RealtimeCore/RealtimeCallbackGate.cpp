#include "RealtimeCallbackGate.h"

#include <atomic>
#include <cstdint>
#include <thread>

namespace {

constexpr uint64_t kCountMask = (uint64_t {1} << 62) - 1;
constexpr uint64_t kStateMask = ~kCountMask;
constexpr uint64_t kOpen = uint64_t {0} << 62;
constexpr uint64_t kClosing = uint64_t {1} << 62;
constexpr uint64_t kClosed = uint64_t {2} << 62;

uint64_t state_of(uint64_t word) {
    return word & kStateMask;
}

uint64_t count_of(uint64_t word) {
    return word & kCountMask;
}

void publish_max_ack(std::atomic<uint64_t> &ack, uint64_t generation) {
    uint64_t observed = ack.load(std::memory_order_relaxed);
    while (observed < generation
           && !ack.compare_exchange_weak(
               observed,
               generation,
               std::memory_order_release,
               std::memory_order_relaxed
           )) {
    }
}

} // namespace

struct ypq_callback_gate {
    alignas(64) std::atomic<uint64_t> word {kOpen};
    alignas(64) std::atomic<uint64_t> last_ack_generation {0};
};

ypq_callback_gate *ypq_callback_gate_create(void) {
    return new ypq_callback_gate();
}

void ypq_callback_gate_destroy(ypq_callback_gate *gate) {
    delete gate;
}

bool ypq_callback_gate_try_enter(ypq_callback_gate *gate) {
    if (gate == nullptr) {
        return false;
    }
    uint64_t observed = gate->word.load(std::memory_order_acquire);
    while (state_of(observed) == kOpen) {
        const uint64_t count = count_of(observed);
        if (count != 0) {
            return false;
        }
        const uint64_t desired = kOpen | 1;
        if (gate->word.compare_exchange_weak(
                observed,
                desired,
                std::memory_order_acq_rel,
                std::memory_order_acquire
            )) {
            return true;
        }
    }
    return false;
}

void ypq_callback_gate_leave(ypq_callback_gate *gate, uint64_t generation_ack) {
    if (gate == nullptr) {
        return;
    }
    uint64_t observed = gate->word.load(std::memory_order_acquire);
    for (;;) {
        const uint64_t count = count_of(observed);
        if (count == 0) {
            return;
        }
        publish_max_ack(gate->last_ack_generation, generation_ack);
        const uint64_t desired = state_of(observed) | (count - 1);
        if (gate->word.compare_exchange_weak(
                observed,
                desired,
                std::memory_order_release,
                std::memory_order_acquire
            )) {
            return;
        }
    }
}

bool ypq_callback_gate_begin_closing(ypq_callback_gate *gate) {
    if (gate == nullptr) {
        return false;
    }
    uint64_t observed = gate->word.load(std::memory_order_acquire);
    while (state_of(observed) == kOpen) {
        const uint64_t desired = kClosing | count_of(observed);
        if (gate->word.compare_exchange_weak(
                observed,
                desired,
                std::memory_order_acq_rel,
                std::memory_order_acquire
            )) {
            return true;
        }
    }
    return false;
}

bool ypq_callback_gate_is_quiescent(const ypq_callback_gate *gate) {
    if (gate == nullptr) {
        return false;
    }
    const uint64_t observed = gate->word.load(std::memory_order_acquire);
    return state_of(observed) == kClosing && count_of(observed) == 0;
}

bool ypq_callback_gate_finish_closing(ypq_callback_gate *gate) {
    if (gate == nullptr) {
        return false;
    }
    uint64_t expected = kClosing;
    return gate->word.compare_exchange_strong(
        expected,
        kClosed,
        std::memory_order_acq_rel,
        std::memory_order_acquire
    );
}

bool ypq_callback_gate_close_and_wait(ypq_callback_gate *gate) {
    if (gate == nullptr) {
        return false;
    }
    (void)ypq_callback_gate_begin_closing(gate);
    for (;;) {
        uint64_t observed = gate->word.load(std::memory_order_acquire);
        const uint64_t state = state_of(observed);
        if (state == kClosed) {
            return true;
        }
        if (state != kClosing) {
            return false;
        }
        if (count_of(observed) == 0
            && gate->word.compare_exchange_weak(
                observed,
                kClosed,
                std::memory_order_acq_rel,
                std::memory_order_acquire
            )) {
            return true;
        }
        std::this_thread::yield();
    }
}

bool ypq_callback_gate_has_idle_acknowledgement(
    const ypq_callback_gate *gate,
    uint64_t generation
) {
    if (gate == nullptr || generation == 0) {
        return false;
    }
    const uint64_t observed = gate->word.load(std::memory_order_acquire);
    return state_of(observed) == kOpen
        && count_of(observed) == 0
        && gate->last_ack_generation.load(std::memory_order_acquire) >= generation;
}

uint64_t ypq_callback_gate_last_ack_generation(const ypq_callback_gate *gate) {
    return gate == nullptr
        ? 0
        : gate->last_ack_generation.load(std::memory_order_acquire);
}
