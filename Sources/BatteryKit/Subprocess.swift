import Foundation

/// Runs a system tool with fixed arguments (no shell) and a deadline, so a stalled `pmset`,
/// `sudo` or `system_profiler` can never wedge the caller. Blocking: call off the main thread.
public enum Subprocess {
    public struct Result: Sendable {
        public var status: Int32
        public var output: Data

        public var succeeded: Bool { status == 0 }
        public var text: String { String(decoding: output, as: UTF8.self) }
    }

    /// stdout and the exit status, or nil when the tool can't start or misses `timeout` (it is
    /// then terminated). stderr is discarded.
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 10) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        // Drain stdout on another thread: reading after `waitUntilExit` would deadlock once the
        // pipe buffer fills, and reading here would block past the deadline.
        let done = DispatchSemaphore(value: 0)
        let box = OutputBox()
        DispatchQueue.global(qos: .utility).async {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: box.data)
    }

    /// Written once by the reader thread before `done.signal()`, read after `done.wait()`.
    private final class OutputBox: @unchecked Sendable {
        var data = Data()
    }
}
