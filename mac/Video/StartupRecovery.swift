import Foundation

/// One finite recovery attempt per stream epoch. Duplicate readiness messages
/// cannot restart its retry schedule or extend its presentation deadline.
struct StartupRecovery {
    static let readinessTimeoutNanoseconds: UInt64 = 12_000_000_000
    static let retryOffsetsNanoseconds: [UInt64] = [100_000_000, 300_000_000]
    static let timeoutNanoseconds: UInt64 = 3_000_000_000
    private(set) var epoch: UInt32?
    private var pending = false

    mutating func begin(epoch: UInt32) -> Bool {
        guard self.epoch != epoch else { return false }
        self.epoch = epoch
        pending = true
        return true
    }

    func isPending(epoch: UInt32) -> Bool { pending && self.epoch == epoch }

    mutating func cancel() { pending = false }
}
