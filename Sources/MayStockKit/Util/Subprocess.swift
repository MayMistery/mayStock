import Foundation

/// Runs one external command to completion, under a deadline it always honours.
///
/// Both places MayStock shells out from — the `okx` CLI bridge and the external
/// script engine — had grown their own copy of this plumbing, and their own
/// copy of the same defect: the watchdog skipped the timeout whenever the child
/// had already exited.
///
/// That case is not hypothetical, and it is not benign. A CLI that leaves a
/// background child holding the stdout it inherited — a version check, a
/// spawned helper — exits immediately while the pipe stays open behind it. So
/// `readDataToEndOfFile` never returns, and when the watchdog finally looks it
/// sees `isRunning == false`, concludes there is nothing to kill, and returns
/// **without resuming the continuation**. The caller stays suspended for good.
/// In the trading loop that meant a tick that never came back, an engine that
/// stopped managing open positions, and no error anywhere to say so.
///
/// Two rules follow, and they are the whole reason this type exists:
///
/// * the deadline resumes the caller **unconditionally** — a live child is
///   killed, a departed one is simply reported;
/// * output is drained through readability handlers rather than a blocking
///   read, so a pipe that never reaches EOF costs no thread at all. The old
///   code parked two per call, which under a repeatedly-wedging CLI would
///   exhaust the very pool its watchdog was scheduled on.
enum Subprocess {

    /// A command that ran and said something, whatever its exit code.
    struct Outcome: Sendable {
        let exitCode: Int32
        let stdout: Data
        let stderr: Data

        var stdoutText: String { String(data: stdout, encoding: .utf8) ?? "" }
        var stderrText: String { String(data: stderr, encoding: .utf8) ?? "" }
    }

    /// A command that produced no usable outcome. Callers map these onto their
    /// own error type; the distinction that matters to all of them is that
    /// `timedOut` says nothing about whether the work was done.
    enum Failure: Error {
        case couldNotLaunch(String)
        case timedOut(TimeInterval)
        case outputTooLarge(limit: Int)
    }

    /// The deadline runs here rather than on a global concurrent queue: a timer
    /// whose job is to break a stall must never be queued behind one.
    private static let watchdog = DispatchQueue(label: "com.maystock.subprocess.watchdog")

    /// How long a terminated child gets to die politely before SIGKILL.
    private static let terminateGrace: TimeInterval = 2

    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        stdin input: Data? = nil,
        timeout: TimeInterval,
        maxOutputBytes: Int = Int.max
    ) async throws -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe = input.map { _ in Pipe() }
        if let inPipe { process.standardInput = inPipe }

        return try await withCheckedThrowingContinuation { continuation in
            let state = State(limit: maxOutputBytes)
            let outHandle = outPipe.fileHandleForReading
            let errHandle = errPipe.fileHandleForReading

            /// Resume exactly once, and stop listening on the way out.
            func settle(_ resume: () -> Void) {
                guard state.claim() else { return }
                // Torn down off whichever handler may be running right now:
                // releasing a closure from inside itself is a trap not worth
                // walking into for the sake of a few microseconds.
                watchdog.async {
                    outHandle.readabilityHandler = nil
                    errHandle.readabilityHandler = nil
                }
                resume()
            }

            /// Both pipes at EOF *and* the child reaped: everything it wrote is
            /// in hand, and the exit status is final. Waiting for EOF rather
            /// than for termination alone is what stops a fast writer's last
            /// chunk being dropped on the floor.
            func settleIfComplete() {
                guard let exitCode = state.completion else { return }
                settle {
                    if let limit = state.overflowLimit {
                        continuation.resume(throwing: Failure.outputTooLarge(limit: limit))
                    } else {
                        continuation.resume(returning: Outcome(
                            exitCode: exitCode, stdout: state.stdout, stderr: state.stderr))
                    }
                }
            }

            for (handle, isStdout) in [(outHandle, true), (errHandle, false)] {
                handle.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    guard !chunk.isEmpty else {
                        handle.readabilityHandler = nil
                        state.markEOF(isStdout: isStdout)
                        settleIfComplete()
                        return
                    }
                    state.append(chunk, isStdout: isStdout)
                }
            }

            process.terminationHandler = { process in
                state.recordExit(process.terminationStatus)
                settleIfComplete()
            }

            do {
                try process.run()
            } catch {
                settle {
                    continuation.resume(
                        throwing: Failure.couldNotLaunch(String(describing: error)))
                }
                return
            }

            if let inPipe, let input {
                // Written off the calling thread: a child that never reads its
                // stdin would otherwise block us the moment the pipe fills.
                DispatchQueue.global(qos: .userInitiated).async {
                    let handle = inPipe.fileHandleForWriting
                    try? handle.write(contentsOf: input)
                    try? handle.close()
                }
            }

            watchdog.asyncAfter(deadline: .now() + timeout) {
                guard !state.isSettled else { return }
                if process.isRunning {
                    process.terminate()
                    watchdog.asyncAfter(deadline: .now() + terminateGrace) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
                // Unconditional, and this is the whole point: an exited child
                // whose pipes a surviving grandchild still holds open is
                // precisely the case that used to slip past here and leave the
                // caller suspended forever.
                settle { continuation.resume(throwing: Failure.timedOut(timeout)) }
            }
        }
    }

    /// Everything the two handlers and the watchdog share, behind one lock:
    /// what has been read, whether each pipe reached EOF, the exit status, and
    /// whether anyone has resumed the caller yet.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var out = Data()
        private var err = Data()
        private var outAtEOF = false
        private var errAtEOF = false
        private var status: Int32?
        private var overflowed = false
        private var settled = false

        init(limit: Int) { self.limit = limit }

        func append(_ data: Data, isStdout: Bool) {
            lock.lock(); defer { lock.unlock() }
            guard !overflowed else { return }
            if isStdout { out.append(data) } else { err.append(data) }
            // Enforced as the bytes arrive, not once they have all landed: the
            // point of a cap is to not be holding the runaway output at all.
            if out.count + err.count > limit {
                overflowed = true
                out = Data()
                err = Data()
            }
        }

        func markEOF(isStdout: Bool) {
            lock.lock(); defer { lock.unlock() }
            if isStdout { outAtEOF = true } else { errAtEOF = true }
        }

        func recordExit(_ code: Int32) {
            lock.lock(); defer { lock.unlock() }
            status = code
        }

        /// The exit status, but only once there is nothing left to read.
        var completion: Int32? {
            lock.lock(); defer { lock.unlock() }
            guard outAtEOF, errAtEOF else { return nil }
            return status
        }

        var overflowLimit: Int? {
            lock.lock(); defer { lock.unlock() }
            return overflowed ? limit : nil
        }

        var stdout: Data { lock.lock(); defer { lock.unlock() }; return out }
        var stderr: Data { lock.lock(); defer { lock.unlock() }; return err }

        /// Guarantees exactly one of {completion, watchdog, launch failure}
        /// resumes the continuation.
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if settled { return false }
            settled = true
            return true
        }

        var isSettled: Bool { lock.lock(); defer { lock.unlock() }; return settled }
    }
}
