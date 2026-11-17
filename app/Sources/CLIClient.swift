import Foundation

struct Account: Codable, Identifiable, Equatable {
    let id: String
    var label: String
    var email: String?
    var dir: String
    var color: String
    var ready: Bool
}

struct Importable: Codable, Identifiable, Equatable {
    var email: String
    var label: String
    var id: String { email }
}

struct Listing: Codable {
    var active: String?
    var accounts: [Account]
    var importable: [Importable]?
}

struct SwitchResult: Codable {
    var active: String
    var label: String
    var email: String?
    var previous: String?
}

struct StatusResult: Codable {
    var id: String
    var ready: Bool
    var email: String?
}

struct ConductorResult: Codable {
    var moved: [Int]
    var skipped_busy: [Int]
    var unsupported: Bool
    var pending: Int
}

struct UpdateInfo: Codable {
    var available: Bool
    var reason: String?     // set when this copy can't update itself (not a git clone, offline, local changes)
    var message: String
}

struct UpdateStart: Codable {
    var started: Bool
    var message: String
}

struct CLIError: Error, Codable {
    var error: String
    var code: String
}

/// Runs `claude-switch … --json`. All account logic lives in the CLI; the app never touches the keychain.
enum CLIClient {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static var binary: String {
        ProcessInfo.processInfo.environment["CLAUDE_SWITCH_BIN"]
            ?? home.appendingPathComponent(".local/bin/claude-switch").path
    }

    static var accountsHome: URL {
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_ACCOUNTS_HOME"] {
            return URL(fileURLWithPath: custom)
        }
        return home.appendingPathComponent(".claude-accounts")
    }

    static func run(_ args: [String]) async throws -> Data {
        try await start(args).value
    }

    /// Starts `claude-switch … --json`; `cancel()` on the returned handle stops it (and its children).
    static func start(_ args: [String]) -> RunningCommand {
        let cmd = RunningCommand()
        cmd.task = Task.detached(priority: .userInitiated) { try execute(args, command: cmd) }
        return cmd
    }

    private static func execute(_ args: [String], command: RunningCommand) throws -> Data {
        let p = command.process
        do {
            p.executableURL = URL(fileURLWithPath: binary)
            p.arguments = args + ["--json"]
            var env = ProcessInfo.processInfo.environment
            // launchd gives apps a bare PATH; Claude Code lives in ~/.local/bin.
            let localBin = home.appendingPathComponent(".local/bin").path
            env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin") + ":\(localBin):/opt/homebrew/bin:/usr/local/bin"
            env.removeValue(forKey: "CLAUDE_CONFIG_DIR")
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            // Cancel may arrive before the process exists; start-or-skip is decided under the same lock.
            try command.startUnlessCancelled()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationReason == .uncaughtSignal || p.terminationStatus == 143 {
                throw CLIError(error: "Cancelled", code: "cancelled")
            }
            if p.terminationStatus != 0 {
                if let err = try? JSONDecoder().decode(CLIError.self, from: data) { throw err }
                throw CLIError(error: "claude-switch failed (exit \(p.terminationStatus))", code: "error")
            }
            return data
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, _ args: [String]) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await run(args))
    }
}

final class RunningCommand: @unchecked Sendable {
    let process = Process()
    var task: Task<Data, Error>!
    var value: Data { get async throws { try await task.value } }

    func decode<T: Decodable>(_ type: T.Type) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await task.value)
    }

    private let lock = NSLock()
    private var cancelled = false

    /// Starts the process, unless `cancel()` already came in (a quick Cancel click can beat the launch).
    func startUnlessCancelled() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CLIError(error: "Cancelled", code: "cancelled") }
        try process.run()
    }

    /// SIGTERM: claude-switch then stops the browser-wait process it started.
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if process.isRunning { process.terminate() }
    }
}
