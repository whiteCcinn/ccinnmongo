import Darwin
import Foundation
import os

/// Runs a subprocess to completion with a timeout and cooperative cancellation, draining stdout and
/// stderr concurrently so large outputs can never deadlock the child.
///
/// Hard bounds: cancellation that arrives before launch is honoured right after launch, SIGTERM is
/// escalated to SIGKILL, and a grandchild that keeps the pipes open cannot delay the result by more
/// than a short drain grace period.
public enum ProcessRunner {
    public struct Output: Sendable {
        public let status: Int32
        public let stdout: Data
        public let stderr: Data
    }

    private final class State: @unchecked Sendable {
        // All mutable fields are guarded by `lock`.
        let lock = OSAllocatedUnfairLock()
        var timedOut = false
        var cancelled = false
        var started = false
        var finished = false
        var resumed = false
        var stdout = Data()
        var stderr = Data()
        let process: Process

        init(process: Process) { self.process = process }

        /// Records why the process must stop and terminates it if it is already running.
        func stop(timedOut timeout: Bool) {
            let shouldTerminate: Bool = lock.withLock {
                guard !finished else { return false }
                if timeout { timedOut = true } else { cancelled = true }
                return started
            }
            if shouldTerminate { terminate() }
        }

        func terminate() {
            guard process.isRunning else { return }
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [process] in
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }

        /// Returns true exactly once.
        func claimResume() -> Bool {
            lock.withLock {
                guard !resumed else { return false }
                resumed = true
                return true
            }
        }
    }

    public static func run(executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL?,
                           timeout: Duration) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if !environment.isEmpty { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice
        let state = State(process: process)
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: AgentError.cancelled)
                    return
                }
                let group = DispatchGroup()
                for (pipe, isStdout) in [(stdoutPipe, true), (stderrPipe, false)] {
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        state.lock.withLock {
                            if isStdout { state.stdout = data } else { state.stderr = data }
                        }
                        group.leave()
                    }
                }

                @Sendable func finish(status: Int32) {
                    guard state.claimResume() else { return }
                    let (timedOut, cancelled, out, err) = state.lock.withLock { () -> (Bool, Bool, Data, Data) in
                        state.finished = true
                        return (state.timedOut, state.cancelled, state.stdout, state.stderr)
                    }
                    if cancelled {
                        continuation.resume(throwing: AgentError.cancelled)
                    } else if timedOut {
                        continuation.resume(throwing: AgentError.timedOut(Int(seconds)))
                    } else {
                        continuation.resume(returning: Output(status: status, stdout: out, stderr: err))
                    }
                }

                process.terminationHandler = { finishedProcess in
                    let status = finishedProcess.terminationStatus
                    DispatchQueue.global().async {
                        // Wait for the pipes to drain, but not forever (a grandchild may hold them open).
                        _ = group.wait(timeout: .now() + 2)
                        finish(status: status)
                    }
                }
                do {
                    try process.run()
                } catch {
                    try? stdoutPipe.fileHandleForWriting.close()
                    try? stderrPipe.fileHandleForWriting.close()
                    guard state.claimResume() else { return }
                    state.lock.withLock { state.finished = true }
                    continuation.resume(throwing: AgentError.failed("Could not start \(executable.lastPathComponent): \(error.localizedDescription)"))
                    return
                }
                // A cancel/timeout that raced with launch is applied now that the process exists.
                let mustStop = state.lock.withLock { () -> Bool in
                    state.started = true
                    return state.cancelled || state.timedOut
                }
                if mustStop { state.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                    state.stop(timedOut: true)
                }
            }
        } onCancel: {
            state.stop(timedOut: false)
        }
    }
}
