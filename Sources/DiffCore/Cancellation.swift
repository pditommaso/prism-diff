// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import Dispatch
import os

/// A cooperative cancellation token for `TextDiff`.
///
/// Any thread may call `cancel()`. The engine polls the flag at its natural
/// checkpoints (per Myers bisection and every few thousand diagonals inside
/// one, per refinement job and line pair, per pre-pairing batch, every 64k
/// word tokens and every 64k interned lines)
/// and stops with `DiffError.cancelled`. Cancellation is permanent: a token
/// cannot be reset, so create one per diff.
///
/// The flag sits behind an `OSAllocatedUnfairLock` because
/// `Synchronization.Atomic` needs macOS 15 and the package targets macOS 14.
/// It is read rarely enough (thousands of times per second at most) for the
/// lock to be free in practice.
public final class CancellationFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    public init() {}

    /// Requests cancellation. Idempotent.
    public func cancel() {
        state.withLock { $0 = true }
    }

    /// True once `cancel()` has been called.
    public var isCancelled: Bool {
        state.withLock { $0 }
    }
}

extension CancellationFlag: Equatable {
    /// Tokens compare by identity.
    public static func == (lhs: CancellationFlag, rhs: CancellationFlag) -> Bool { lhs === rhs }
}

/// Why a diff did not produce a result.
public enum DiffError: Error, Sendable, Equatable {
    /// The diff's `CancellationFlag` was cancelled, or the task running an
    /// async diff was cancelled. Partial work is discarded.
    case cancelled
    /// The inputs are too large for the operation: a three-way merge of A
    /// and B that together reach 2 GiB.
    case tooLarge
}

extension Optional where Wrapped == CancellationFlag {
    /// True when there is a token and it has been cancelled.
    @inline(__always)
    var isCancelled: Bool {
        switch self {
        case .none: return false
        case .some(let flag): return flag.isCancelled
        }
    }
}

extension TextDiff {

    /// Async variant of `cancellableDiff`: runs on a global dispatch queue,
    /// off the cooperative thread pool, and turns cancellation of the calling
    /// task into cancellation of the diff.
    ///
    /// If `options.cancellation` is set, that token is used (so it can also
    /// be cancelled directly); otherwise a fresh one is made for this call.
    public static func asyncDiff(_ a: [UInt8], _ b: [UInt8],
                                 options: DiffOptions = DiffOptions()) async throws(DiffError) -> TextDiffResult {
        var options = options
        let flag = options.cancellation ?? CancellationFlag()
        options.cancellation = flag
        let run = options
        let outcome: Result<TextDiffResult, DiffError> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: Result(catching: { () throws(DiffError) in
                        try cancellableDiff(a, b, options: run)
                    }))
                }
            }
        } onCancel: {
            flag.cancel()
        }
        return try outcome.get()
    }
}
