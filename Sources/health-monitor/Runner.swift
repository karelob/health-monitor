import Foundation

let VERSION = "1.0.0"
let HOME = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()

// MARK: - Path helpers

func expandTilde(_ path: String) -> String {
    guard path.hasPrefix("~/") else { return path }
    return HOME + path.dropFirst()
}

// MARK: - JSON codec helpers

private func makeEncoder() -> JSONEncoder {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    enc.dateEncodingStrategy = .iso8601
    return enc
}

private func makeDecoder() -> JSONDecoder {
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    return dec
}

// MARK: - IO helpers

func atomicWrite<T: Encodable>(_ value: T, to path: String) throws {
    let data = try makeEncoder().encode(value)
    let expandedPath = expandTilde(path)
    let url = URL(fileURLWithPath: expandedPath)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: nil
    )
    try data.write(to: url, options: .atomic)
}

func loadConfig(from path: String) throws -> AppConfig {
    let data = try Data(contentsOf: URL(fileURLWithPath: expandTilde(path)))
    return try makeDecoder().decode(AppConfig.self, from: data)
}

func loadState(from path: String) -> PulseState {
    guard
        let data = try? Data(contentsOf: URL(fileURLWithPath: expandTilde(path))),
        let state = try? makeDecoder().decode(PulseState.self, from: data)
    else { return [:] }
    return state
}

// MARK: - Transition log

func logTransition(to path: String, message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "\(ts) \(message)\n"
    guard let lineData = line.data(using: .utf8) else { return }
    let expandedPath = expandTilde(path)
    let url = URL(fileURLWithPath: expandedPath)
    if let fh = try? FileHandle(forWritingTo: url) {
        fh.seekToEndOfFile()
        fh.write(lineData)
        try? fh.close()
    } else {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? lineData.write(to: url)
    }
}

// MARK: - CLI arg parsing

struct Args {
    var config: String?
    var output: String?
    var log: String?
    var once = false
    var showHelp = false
    var showVersion = false
}

func parseArgs() -> Args {
    var args = Args()
    var i = 1
    let argv = CommandLine.arguments
    while i < argv.count {
        switch argv[i] {
        case "--config":  i += 1; if i < argv.count { args.config = argv[i] }
        case "--output":  i += 1; if i < argv.count { args.output = argv[i] }
        case "--log":     i += 1; if i < argv.count { args.log    = argv[i] }
        case "--once":    args.once = true
        case "--help", "-h": args.showHelp = true
        case "--version": args.showVersion = true
        default: break
        }
        i += 1
    }
    return args
}

// MARK: - Main

func runMain() async throws {
    let args = parseArgs()

    if args.showVersion {
        print("health-monitor \(VERSION)")
        return
    }
    if args.showHelp {
        print("""
            health-monitor \(VERSION)

            Runs configurable health checks on a schedule and writes a JSON status file.
            Designed to be invoked every few minutes by launchd (macOS) or cron.

            Usage:
              health-monitor [options]

            Options:
              --config <path>   Config file (default: ~/.config/health-monitor/config.json)
              --output <path>   Status JSON output (overrides config; default: ~/.config/health-monitor/system_pulse.json)
              --log <path>      Transitions log (overrides config; default: ~/.config/health-monitor/health_pulse.log)
              --once            Run all checks now, ignore per-check intervals
              --version         Print version
              --help            Print this help

            See pulse_config.example.json for configuration format and check type reference.
            """)
        return
    }

    let configPath = args.config ?? "~/.config/health-monitor/config.json"
    let config: AppConfig
    do {
        config = try loadConfig(from: configPath)
    } catch {
        fputs("health-monitor: cannot load config '\(configPath)': \(error.localizedDescription)\n", stderr)
        exit(1)
    }

    let outputPath = args.output ?? config.output ?? "~/.config/health-monitor/system_pulse.json"
    let logPath    = args.log    ?? config.log    ?? "~/.config/health-monitor/health_pulse.log"
    let statePath  = "~/.config/health-monitor/pulse_state.json"

    var state = loadState(from: statePath)
    let now = Date()

    // Prune state to only checks present in current config (avoids stale output from old configs)
    let configNames = Set(config.checks.map { $0.name })
    state = state.filter { configNames.contains($0.key) }

    // Filter to checks whose interval has elapsed (or run all if --once)
    let due = args.once
        ? config.checks
        : config.checks.filter { check in
            guard let prev = state[check.name]?.lastRun else { return true }
            return now.timeIntervalSince(prev) >= Double(check.interval)
        }

    if !due.isEmpty {
        // Run due checks concurrently
        var fresh: [String: CheckResult] = [:]
        await withTaskGroup(of: (String, CheckResult).self) { group in
            for check in due {
                group.addTask { (check.name, await runCheck(check)) }
            }
            for await (name, result) in group {
                fresh[name] = result
            }
        }

        // Detect transitions and update state
        for (name, result) in fresh {
            if let prev = state[name]?.lastResult {
                if prev.ok != result.ok {
                    let arrow = result.ok ? "UP  " : "DOWN"
                    let detail = result.ok
                        ? (result.latencyMs.map { " (\($0) ms)" } ?? "")
                        : (result.error.map { " (\($0))" } ?? "")
                    logTransition(to: logPath, message: "[\(arrow)] \(name)\(detail)")
                }
            } else {
                let status = result.ok ? "ok" : "FAIL\(result.error.map { " – \($0)" } ?? "")"
                logTransition(to: logPath, message: "[INIT] \(name): \(status)")
            }
            state[name] = CheckState(lastRun: now, lastResult: result)
        }
    }

    // Build output from full state (all checks, not just those that ran this cycle)
    let allResults = Dictionary(uniqueKeysWithValues: state.map { ($0.key, $0.value.lastResult) })
    let pulse = SystemPulse(checkedAt: now, checks: allResults)

    do {
        try atomicWrite(pulse, to: outputPath)
        try atomicWrite(state, to: statePath)
    } catch {
        fputs("health-monitor: write failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}
