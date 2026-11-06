import Foundation

/// Serializes Core Audio control-plane lifecycle work. Real-time callbacks
/// never enqueue here; they operate only on already-published snapshots.
final class CoreAudioHALExecutor {
    private let queue: DispatchQueue

    init(label: String = "com.mankeipun.yinpinqiehuan.coreaudio-hal") {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func async(_ operation: @escaping @Sendable () -> Void) {
        queue.async(execute: operation)
    }

    /// Executes a finite HAL lifecycle operation on the same serial queue and
    /// bridges its result back to the caller. Realtime callbacks must never
    /// call this API.
    func perform<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
