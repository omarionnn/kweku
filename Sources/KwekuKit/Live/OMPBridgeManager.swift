import Foundation

/// Executes `execute_omp_command` tool calls by running oh-my-pi headless
/// (`omp -p`, the documented print mode) in the most relevant session's cwd.
///
/// Note on "the active session": injecting a prompt into a running interactive
/// omp TUI isn't possible from outside, so the bridge runs a bounded headless
/// omp in the same working directory instead. Because headless runs load the
/// kweku-watch extension, the notch reactions come free: the ember pulses
/// while the task runs (agent_start) and the ‼️ eyes fire on completion
/// (agent_end -> waiting) via the existing agent-watch pipeline.
public enum OMPBridgeManager {
    /// Hard cap so a runaway task can't hold the Live session hostage.
    public static let maxRunTime = "10m"
    /// Tool responses are context — keep them bounded.
    public static let maxOutputChars = 4000

    /// Run the prompt; returns combined output (truncated) for the
    /// `toolResponse` frame. Never throws — errors come back as text so the
    /// model can react to them.
    public static func dispatchCommand(_ prompt: String, cwd: String?) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: run(prompt, cwd: cwd))
            }
        }
    }

    private static func run(_ prompt: String, cwd: String?) -> String {
        let process = Process()
        // Login shell resolves the user's PATH (omp install location) and the
        // provider API keys omp needs.
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "omp -p --max-time \(maxRunTime) \(shellQuote(prompt))"]
        if let cwd, FileManager.default.fileExists(atPath: cwd) {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do { try process.run() } catch {
            return "Failed to launch omp: \(error.localizedDescription)"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var output = String(data: data, encoding: .utf8) ?? ""
        output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.isEmpty {
            output = process.terminationStatus == 0
                ? "(completed with no output)"
                : "omp exited with status \(process.terminationStatus)"
        }
        if output.count > maxOutputChars {
            output = String(output.suffix(maxOutputChars))
        }
        return output
    }

    /// Single-quote shell escaping (unit-tested).
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
