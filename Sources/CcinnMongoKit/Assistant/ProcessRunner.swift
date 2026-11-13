import Foundation
import os

/// Runs a subprocess to completion with a timeout and cooperative cancellation, draining stdout and
/// stderr concurrently so large outputs can never deadlock the child.
public enum ProcessRunner {
    public struct Output: Sendable {
        public let status: Int32
        public let stdout: Data
        public let stderr: Data
    }

    private final class State: @unchecked Sendable {
        // Guarded by `lock`.
        let lock = OSAllocatedUnfairLock()
        var timedOut = false
        var cancelled = false
        var finished = false
        var stdout = Data()
        var stderr = Data()
        let process: Process

        init(process: Process) { self.process = process }

        func stop(timedOut timeout: Bool) {
            let shouldTerminate: Bool = lock.withLock {
                guard !finished else { return false }
                if timeout { timedOut = true } else { cancelled = true }
                return true
            }
            if shouldTerminate, process.isRunning { process.terminate() }
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
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    state.lock.withLock { state.stdout = data }
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    state.lock.withLock { state.stderr = data }
                    group.leave()
                }
                process.terminationHandler = { finishedProcess in
                    group.notify(queue: .global()) {
                        let (timedOut, cancelled, out, err) = state.lock.withLock { () -> (Bool, Bool, Data, Data) in
                            state.finished = true
                            return (state.timedOut, state.cancelled, state.stdout, state.stderr)
                        }
                        if cancelled {
                            continuation.resume(throwing: AgentError.cancelled)
                        } else if timedOut {
                            continuation.resume(throwing: AgentError.timedOut(Int(seconds)))
                        } else {
                            continuation.resume(returning: Output(status: finishedProcess.terminationStatus, stdout: out, stderr: err))
                        }
                    }
                }
                do {
                    try process.run()
                } catch {
                    // Close our ends so the reader threads finish; terminationHandler never fires.
                    try? stdoutPipe.fileHandleForWriting.close()
                    try? stderrPipe.fileHandleForWriting.close()
                    state.lock.withLock { state.finished = true }
                    continuation.resume(throwing: AgentError.failed("Could not start \(executable.lastPathComponent): \(error.localizedDescription)"))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                    state.stop(timedOut: true)
                }
            }
        } onCancel: {
            state.stop(timedOut: false)
        }
    }
}
