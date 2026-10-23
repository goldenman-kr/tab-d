import Foundation

/// Races a callback against a deadline without waiting for a framework task to
/// finish. A missing or duplicate callback cannot strand/resume a continuation.
enum FrameworkDeadline {
    struct Timeout: LocalizedError {
        let operation: String
        let seconds: TimeInterval
        var errorDescription: String? {
            "ScreenCaptureKit \(operation) timed out after \(seconds) seconds."
        }
    }

    static func wait<Value>(seconds: TimeInterval, operation: String,
                            onLateSuccess: ((Value) -> Void)? = nil,
                            start: (@escaping (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let race = CallbackRace(continuation: continuation, onLateSuccess: onLateSuccess)
            // The deadline owns the race until it fires, including when start
            // deliberately never retains or invokes its callback.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
                race.expire(Timeout(operation: operation, seconds: seconds))
            }
            start { race.complete($0) }
        }
    }

    private final class CallbackRace<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Error>?
        private var expired = false
        private var callbackReceived = false
        private let onLateSuccess: ((Value) -> Void)?

        init(continuation: CheckedContinuation<Value, Error>, onLateSuccess: ((Value) -> Void)?) {
            self.continuation = continuation
            self.onLateSuccess = onLateSuccess
        }

        func complete(_ result: Result<Value, Error>) {
            lock.lock()
            guard !callbackReceived else { lock.unlock(); return }
            callbackReceived = true
            let waiting = continuation
            continuation = nil
            let wasExpired = expired
            lock.unlock()
            if let waiting { waiting.resume(with: result) }
            else if wasExpired, case .success(let value) = result { onLateSuccess?(value) }
        }

        func expire(_ error: Error) {
            lock.lock()
            guard let waiting = continuation else { lock.unlock(); return }
            continuation = nil
            expired = true
            lock.unlock()
            waiting.resume(throwing: error)
        }
    }
}
