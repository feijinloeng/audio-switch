#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ypq_callback_gate ypq_callback_gate;

ypq_callback_gate *ypq_callback_gate_create(void);
void ypq_callback_gate_destroy(ypq_callback_gate *gate);

/// The callback admission linearization point. The gate enforces single-flight
/// execution: a second callback is rejected while one lease is active.
/// Successful callers must pair it with `leave`; callers rejected after
/// closing must return immediately.
bool ypq_callback_gate_try_enter(ypq_callback_gate *gate);
void ypq_callback_gate_leave(ypq_callback_gate *gate, uint64_t generation_ack);

/// Control-plane lifecycle operations. Only a closing gate with zero admitted
/// callbacks may be finished and have its short-lived resources reclaimed.
bool ypq_callback_gate_begin_closing(ypq_callback_gate *gate);
bool ypq_callback_gate_is_quiescent(const ypq_callback_gate *gate);
bool ypq_callback_gate_finish_closing(ypq_callback_gate *gate);
/// Begins closing if necessary, waits for the admitted callback to leave, and
/// publishes the closed state. After this returns true no callback can touch
/// gate-owned state.
bool ypq_callback_gate_close_and_wait(ypq_callback_gate *gate);
/// A single-flight lifetime proof used by immutable snapshot owners. A true
/// result means no older callback is active and the requested generation was
/// completed before the gate became idle.
bool ypq_callback_gate_has_idle_acknowledgement(
    const ypq_callback_gate *gate,
    uint64_t generation
);
uint64_t ypq_callback_gate_last_ack_generation(const ypq_callback_gate *gate);

#ifdef __cplusplus
}
#endif
