import Foundation
import Testing
@testable import EngineKit

enum TestSupport {

    /// The Stockfish network. Tests read it from the repository by absolute
    /// path; the app passes its bundle URL instead. `ENGINEKIT_NNUE_PATH`
    /// overrides it, which is how the tvOS simulator run finds the file when
    /// the repository path is not readable from inside the simulator.
    static let defaultNetworkPath: String = {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        return repository.appendingPathComponent("Apps/ChessTV/Resources/nn-1a298aa575a0.nnue").path
    }()

    static var networkURL: URL? {
        let path = ProcessInfo.processInfo.environment["ENGINEKIT_NNUE_PATH"] ?? defaultNetworkPath
        guard FileManager.default.isReadableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    static let missingNetworkMessage: Comment = """
        Stockfish network not readable at \(defaultNetworkPath). \
        Set ENGINEKIT_NNUE_PATH to a readable copy (on the tvOS simulator the \
        repository path is outside the sandbox).
        """

    /// Number of open file descriptors in this process.
    static func openFileDescriptorCount() -> Int {
        var count = 0
        var limit = rlimit()
        getrlimit(RLIMIT_NOFILE, &limit)
        let maximum = Int32(min(limit.rlim_cur, 4096))
        for fd in 0..<maximum where fcntl(fd, F_GETFD) != -1 {
            count += 1
        }
        return count
    }

    /// Resident size of this process in bytes.
    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    /// Diagnostics go to standard error: while an engine is running the bridge
    /// has duplicated the pipe onto standard output, so `print` would be fed to
    /// Stockfish instead of the test log.
    static func note(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// Collects a whole evaluation stream.
    static func collect(_ stream: AsyncStream<Evaluation>) async -> [Evaluation] {
        var out: [Evaluation] = []
        for await evaluation in stream { out.append(evaluation) }
        return out
    }
}
