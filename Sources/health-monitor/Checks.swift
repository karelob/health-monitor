import Darwin
import Foundation

// Dispatch to check implementation by type name.
func runCheck(_ config: CheckConfig) async -> CheckResult {
    switch config.type {
    case "http_ping":   return await httpPing(config)
    case "pid_alive":   return pidAlive(config)
    case "log_fresh":   return logFresh(config)
    case "status_file": return statusFile(config)
    case "ollama_chat": return await ollamaChat(config)
    default:
        return CheckResult(ok: false, error: "unknown check type: \(config.type)")
    }
}

// MARK: - http_ping

// GETs the given URL and returns ok=true if the response is non-empty and HTTP < 400.
// Measures round-trip latency in milliseconds.
func httpPing(_ config: CheckConfig) async -> CheckResult {
    guard let urlStr = config.url, let url = URL(string: urlStr) else {
        return CheckResult(ok: false, error: "invalid or missing url")
    }
    let timeoutSec = TimeInterval(config.timeout ?? 6)
    let sessionCfg = URLSessionConfiguration.ephemeral
    sessionCfg.timeoutIntervalForRequest = timeoutSec
    sessionCfg.timeoutIntervalForResource = timeoutSec
    let session = URLSession(configuration: sessionCfg)

    let start = Date()
    do {
        let (data, response) = try await session.data(from: url)
        let latency = Int(Date().timeIntervalSince(start) * 1000)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
        let ok = !data.isEmpty && statusCode < 400
        return CheckResult(ok: ok, latencyMs: latency,
                           error: ok ? nil : "HTTP \(statusCode)")
    } catch {
        return CheckResult(ok: false, error: error.localizedDescription)
    }
}

// MARK: - ollama_chat

// POSTs a chat completion to Ollama with a metrics summary built from the
// JSON file at metrics_from. Expects model output to be a JSON object with
// score/trend/anomalies/recommendations fields. Stores parsed fields on
// CheckResult so consumers (e.g. NanoClaw background-monitor) can read the
// last analysis directly from system_pulse.json.
//
// Why this lives here, not in NanoClaw: macOS Tahoe Local Network permission
// is granted per-binary. /usr/bin/curl and this hardened-runtime Swift binary
// have it; Homebrew node (adhoc-signed) does not from launchd context. So the
// chat call needs a process that the kernel will let through.
func ollamaChat(_ config: CheckConfig) async -> CheckResult {
    guard let urlStr = config.url, let url = URL(string: urlStr) else {
        return CheckResult(ok: false, error: "invalid or missing url")
    }
    guard let model = config.model else {
        return CheckResult(ok: false, error: "ollama_chat requires `model`")
    }

    // Build user prompt from metrics file (best-effort — empty payload still ok).
    // Strip self-key from metrics so the model doesn't hallucinate about its
    // own previous result (e.g. "tier2_ollama is offline" because the snapshot
    // it's reading still shows the prior failure).
    var metricsSummary = "(no metrics source configured)"
    if let mf = config.metricsFrom {
        let mp = expandTilde(mf)
        if let data = try? Data(contentsOf: URL(fileURLWithPath: mp)) {
            // Try to parse as JSON and remove our own check key from `checks`
            if var parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               var checks = parsed["checks"] as? [String: Any] {
                checks.removeValue(forKey: config.name)
                parsed["checks"] = checks
                if let cleaned = try? JSONSerialization.data(
                    withJSONObject: parsed,
                    options: [.prettyPrinted, .sortedKeys]),
                   let s = String(data: cleaned, encoding: .utf8) {
                    metricsSummary = s.count > 8192
                        ? String(s.prefix(8192)) + "\n…(truncated)"
                        : s
                } else if let s = String(data: data, encoding: .utf8) {
                    metricsSummary = s
                }
            } else if let s = String(data: data, encoding: .utf8) {
                metricsSummary = s.count > 8192 ? String(s.prefix(8192)) + "\n…(truncated)" : s
            }
        } else {
            metricsSummary = "(metrics file unreadable: \(mp))"
        }
    }

    let userPrompt = """
    SYSTEM_PULSE (latest snapshot, JSON):
    \(metricsSummary)

    Analyze. Output JSON only:
    {"score":1-10,"trend":"improving|stable|degrading","anomalies":["..."],"recommendations":["..."]}
    """

    let systemPrompt = config.system ?? "You are a system health analyst. Output ONLY valid JSON, no explanation."

    let body: [String: Any] = [
        "model": model,
        "messages": [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userPrompt]
        ],
        "think": false,
        "stream": false
    ]

    guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
        return CheckResult(ok: false, error: "failed to serialize request")
    }

    let timeoutSec = TimeInterval(config.timeout ?? 120)
    let sessionCfg = URLSessionConfiguration.ephemeral
    sessionCfg.timeoutIntervalForRequest = timeoutSec
    sessionCfg.timeoutIntervalForResource = timeoutSec
    let session = URLSession(configuration: sessionCfg)

    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = payload

    let start = Date()
    do {
        let (data, response) = try await session.data(for: req)
        let latency = Int(Date().timeIntervalSince(start) * 1000)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        if statusCode >= 400 {
            return CheckResult(ok: false, latencyMs: latency, error: "HTTP \(statusCode)")
        }

        // Parse Ollama response envelope to extract assistant content
        guard
            let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = envelope["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            return CheckResult(ok: false, latencyMs: latency, error: "malformed response envelope")
        }

        // Parse model JSON output (model may include surrounding text — best-effort
        // extract first {...} block)
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonStr: String
        if let firstBrace = trimmed.firstIndex(of: "{"),
           let lastBrace = trimmed.lastIndex(of: "}") {
            jsonStr = String(trimmed[firstBrace...lastBrace])
        } else {
            return CheckResult(
                ok: true, latencyMs: latency,
                lastStatus: "no-json: \(trimmed.prefix(80))",
                error: nil
            )
        }
        guard
            let parsed = try? JSONSerialization.jsonObject(with: Data(jsonStr.utf8)) as? [String: Any]
        else {
            return CheckResult(
                ok: true, latencyMs: latency,
                lastStatus: "parse-fail: \(jsonStr.prefix(80))",
                error: nil
            )
        }

        let score = parsed["score"] as? Int
        let trend = parsed["trend"] as? String
        let anomalies = parsed["anomalies"] as? [String]
        let recommendations = parsed["recommendations"] as? [String]
        let lastStatus: String? = score.map { "score=\($0)" + (trend.map { " trend=\($0)" } ?? "") }

        return CheckResult(
            ok: true,
            latencyMs: latency,
            lastStatus: lastStatus,
            score: score,
            trend: trend,
            anomalies: anomalies,
            recommendations: recommendations
        )
    } catch {
        return CheckResult(ok: false, error: error.localizedDescription)
    }
}

// MARK: - pid_alive

// Reads a PID from a pidfile and checks whether the process is running via kill(pid, 0).
func pidAlive(_ config: CheckConfig) -> CheckResult {
    guard let pidfileStr = config.pidfile else {
        return CheckResult(ok: false, error: "no pidfile configured")
    }
    let pidfilePath = expandTilde(pidfileStr)
    guard
        let content = try? String(contentsOfFile: pidfilePath, encoding: .utf8),
        let pid = Int32(content.trimmingCharacters(in: .whitespacesAndNewlines))
    else {
        return CheckResult(ok: false, error: "pidfile missing or non-numeric: \(pidfilePath)")
    }
    let alive = kill(pid, 0) == 0
    return CheckResult(ok: alive, pid: Int(pid),
                       error: alive ? nil : "process \(pid) not running")
}

// MARK: - log_fresh

// Checks that a log file's modification time is within the configured threshold.
// Optionally also verifies that a regex pattern exists in the last 8 KB of the file.
func logFresh(_ config: CheckConfig) -> CheckResult {
    guard let logStr = config.log else {
        return CheckResult(ok: false, error: "no log path configured")
    }
    let logPath = expandTilde(logStr)
    guard
        let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
        let mtime = attrs[.modificationDate] as? Date
    else {
        return CheckResult(ok: false, error: "log file not found: \(logPath)")
    }

    let ageMin = -mtime.timeIntervalSinceNow / 60.0
    let ageH   = ageMin / 60.0

    if let maxMin = config.maxAgeMin {
        let ok = ageMin <= maxMin
        return CheckResult(ok: ok, ageMin: ageMin,
                           error: ok ? nil : "log stale: \(Int(ageMin)) min (max \(Int(maxMin)) min)")
    }
    if let maxH = config.maxAgeH {
        let ok = ageH <= maxH
        return CheckResult(ok: ok, ageH: ageH,
                           error: ok ? nil : "log stale: \(Int(ageH))h (max \(Int(maxH))h)")
    }
    if let pattern = config.pattern {
        let found = lastKilobytes(of: logPath, contain: pattern)
        return CheckResult(ok: found, ageMin: ageMin,
                           error: found ? nil : "pattern not found in last 8 KB: \(pattern)")
    }
    return CheckResult(ok: true, ageMin: ageMin)
}

// MARK: - status_file

// Reads a JSON status file. Checks that:
// 1. The file exists and parses as JSON.
// 2. Its modification time is within max_age_h (if configured).
// 3. A "status" or "ok" field indicates success.
func statusFile(_ config: CheckConfig) -> CheckResult {
    guard let pathStr = config.path else {
        return CheckResult(ok: false, error: "no path configured")
    }
    let filePath = expandTilde(pathStr)
    guard
        let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return CheckResult(ok: false, error: "status file missing or invalid JSON: \(filePath)")
    }

    // File mtime age check
    var fileAgeH: Double? = nil
    if let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
       let mtime = attrs[.modificationDate] as? Date {
        let h = -mtime.timeIntervalSinceNow / 3600.0
        fileAgeH = h
        if let maxH = config.maxAgeH, h > maxH {
            return CheckResult(ok: false, ageH: h,
                               error: "status file stale: \(Int(h))h (max \(Int(maxH))h)")
        }
    }

    // Embedded timestamp check ("ts" key, ISO8601 or RFC3339)
    var embedAgeH: Double? = nil
    if let tsStr = json["ts"] as? String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = fmt.date(from: tsStr) ?? ISO8601DateFormatter().date(from: tsStr)
        if let ts = ts {
            let h = -ts.timeIntervalSinceNow / 3600.0
            embedAgeH = h
            if let maxH = config.maxAgeH, h > maxH {
                return CheckResult(ok: false, ageH: h,
                                   error: "embedded ts stale: \(Int(h))h (max \(Int(maxH))h)")
            }
        }
    }

    let ageH = embedAgeH ?? fileAgeH

    // Status/ok field
    let statusStr = json["status"] as? String
    let okFromBool = json["ok"] as? Bool
    let ok: Bool
    if let b = okFromBool {
        ok = b
    } else if let s = statusStr {
        ok = s == "success" || s == "ok" || s == "healthy"
    } else {
        ok = true
    }

    return CheckResult(ok: ok, ageH: ageH, lastStatus: statusStr,
                       error: ok ? nil : "status=\(statusStr ?? "unknown")")
}

// MARK: - Helpers

// Returns true if the last 8 KB of a file contain any line matching the given regex pattern.
func lastKilobytes(of path: String, contain pattern: String) -> Bool {
    guard let fh = FileHandle(forReadingAtPath: path) else { return false }
    defer { try? fh.close() }
    let size = fh.seekToEndOfFile()
    let readSize = min(size, 8192)
    guard readSize > 0 else { return false }
    fh.seek(toFileOffset: size - readSize)
    let data = fh.readDataToEndOfFile()
    guard let content = String(data: data, encoding: .utf8) else { return false }
    return content.range(of: pattern, options: .regularExpression) != nil
}
