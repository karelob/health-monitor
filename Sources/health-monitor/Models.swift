import Foundation

// MARK: - Configuration

struct CheckConfig: Decodable, Sendable {
    let name: String
    let type: String
    let interval: Int       // seconds between runs

    // http_ping
    let url: String?
    let timeout: Int?       // connect + read timeout in seconds (default 6)

    // pid_alive
    let pidfile: String?

    // status_file
    let path: String?
    let maxAgeH: Double?    // fail if file or embedded ts is older than N hours

    // log_fresh
    let log: String?
    let pattern: String?    // optional regex: search last 8 KB for this pattern
    let maxAgeMin: Double?  // fail if log mtime older than N minutes

    // ollama_chat: POST to Ollama /api/chat. Reuses `url` (chat endpoint),
    // `timeout` (request timeout). Reads metrics from `metricsFrom` (path to
    // system_pulse.json), passes summary to model, expects JSON reply with
    // {"score":1-10,"trend":"...","anomalies":[...],"recommendations":[...]}.
    let model: String?
    let system: String?
    let metricsFrom: String?  // path to system_pulse.json (or other JSON metrics source)

    enum CodingKeys: String, CodingKey {
        case name, type, interval, url, timeout, pidfile, path, log, pattern
        case model, system
        case maxAgeH = "max_age_h"
        case maxAgeMin = "max_age_min"
        case metricsFrom = "metrics_from"
    }
}

struct AppConfig: Decodable {
    let output: String?     // system_pulse.json path
    let log: String?        // transitions log path
    let checks: [CheckConfig]
}

// MARK: - Check result

struct CheckResult: Codable, Sendable {
    let ok: Bool
    let checkedAt: Date
    var latencyMs: Int?     // http_ping / ollama_chat: round-trip ms
    var pid: Int?           // pid_alive: pid read from pidfile
    var ageH: Double?       // status_file / log_fresh: hours since last update
    var ageMin: Double?     // log_fresh: minutes since last update
    var lastStatus: String? // status_file: value of "status" field in JSON
    var error: String?      // failure reason

    // ollama_chat: parsed response fields
    var score: Int?
    var trend: String?
    var anomalies: [String]?
    var recommendations: [String]?

    enum CodingKeys: String, CodingKey {
        case ok, error, pid, score, trend, anomalies, recommendations
        case checkedAt = "checked_at"
        case latencyMs = "latency_ms"
        case ageH = "age_h"
        case ageMin = "age_min"
        case lastStatus = "last_status"
    }

    init(
        ok: Bool,
        latencyMs: Int? = nil,
        pid: Int? = nil,
        ageH: Double? = nil,
        ageMin: Double? = nil,
        lastStatus: String? = nil,
        error: String? = nil,
        score: Int? = nil,
        trend: String? = nil,
        anomalies: [String]? = nil,
        recommendations: [String]? = nil
    ) {
        self.ok = ok
        self.checkedAt = Date()
        self.latencyMs = latencyMs
        self.pid = pid
        self.ageH = ageH
        self.ageMin = ageMin
        self.lastStatus = lastStatus
        self.error = error
        self.score = score
        self.trend = trend
        self.anomalies = anomalies
        self.recommendations = recommendations
    }
}

// MARK: - State (persisted between runs)

struct CheckState: Codable {
    var lastRun: Date
    var lastResult: CheckResult
}

typealias PulseState = [String: CheckState]

// MARK: - Output

struct SystemPulse: Encodable {
    let checkedAt: Date
    let checks: [String: CheckResult]

    enum CodingKeys: String, CodingKey {
        case checkedAt = "checked_at"
        case checks
    }
}
