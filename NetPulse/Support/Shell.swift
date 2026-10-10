import Foundation

/// Runs a command-line tool and returns its standard output.
/// Blocking — always call from a background queue or task.
enum Shell {
    @discardableResult
    static func run(_ executable: String, _ arguments: [String] = [], timeout: TimeInterval = 10) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return ""
        }

        // Safety net so a hung tool can never block a monitor forever.
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        return String(decoding: data, as: UTF8.self)
    }

    /// Async wrapper that runs the command off the main thread.
    static func runAsync(_ executable: String, _ arguments: [String] = [], timeout: TimeInterval = 10) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: run(executable, arguments, timeout: timeout))
            }
        }
    }
}
