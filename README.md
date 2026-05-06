# health-monitor

Configurable macOS health monitor — Swift CLI, launchd-managed.

Runs a set of health checks on a schedule and writes a JSON status file. Each check type has its own interval so cheap checks run every 5 minutes and expensive ones only once a day. Designed to be invoked periodically by launchd; each invocation runs only the checks that are due, writes results, and exits.

**Visible by name in macOS System Settings → Privacy & Security** when code-signed.

---

## How it works

```
launchd (every 5 min)
  └─ health-monitor
       ├─ read config.json
       ├─ read pulse_state.json  (which checks ran last, and when)
       ├─ for each check whose interval has elapsed → run (concurrent)
       │    http_ping   — URLSession GET, measure latency
       │    pid_alive   — read pidfile, kill(pid, 0)
       │    log_fresh   — file mtime ± optional regex in last 8 KB
       │    status_file — JSON file age + status/ok field
       ├─ detect UP↔DOWN transitions → append to health_pulse.log
       ├─ write system_pulse.json  (all checks, not just those that ran)
       └─ write pulse_state.json  (updated lastRun timestamps)
```

State is persisted in `pulse_state.json` so checks are not re-run on every launchd invocation — only when their interval has elapsed. On the first run after installation every check runs once regardless of interval.

---

## Installation

```bash
# 1. Build
cd ~/Develop/health-monitor
swift build -c release

# 2. Install to a stable path
mkdir -p ~/.local/bin
cp .build/release/health-monitor ~/.local/bin/health-monitor

# 3. (Recommended) Sign so it appears by name in macOS Security preferences
#    Replace TEAMID with your Apple Developer team ID.
codesign --sign "Apple Development: Your Name (TEAMID)" \
         --options runtime ~/.local/bin/health-monitor
```

After signing, `health-monitor` appears by name in:
**System Settings → Privacy & Security → Full Disk Access** (and other FDA panels).

---

## Configuration

Default path: `~/.config/health-monitor/config.json`

```json
{
  "output": "~/.config/health-monitor/system_pulse.json",
  "log":    "~/.config/health-monitor/health_pulse.log",
  "checks": [
    {
      "name":     "my-api",
      "type":     "http_ping",
      "interval": 300,
      "url":      "http://localhost:8080/health",
      "timeout":  6
    }
  ]
}
```

All `~/` paths are expanded relative to `$HOME`.

See [`pulse_config.example.json`](pulse_config.example.json) for all check types and parameters.

---

## Check types

### `http_ping`

HTTP GET with latency measurement. ok = HTTP < 400 and non-empty body.

```json
{
  "name":     "ollama",
  "type":     "http_ping",
  "interval": 300,
  "url":      "http://10.0.10.70:11434/api/tags",
  "timeout":  6
}
```

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `url`     | yes | — | URL to GET |
| `timeout` | no | 6 | Connect + read timeout in seconds |

Output fields: `ok`, `latency_ms`, `error`

---

### `pid_alive`

Reads a PID file and checks if the process is running via `kill(pid, 0)`.

```json
{
  "name":     "myapp",
  "type":     "pid_alive",
  "interval": 300,
  "pidfile":  "~/.run/myapp.pid"
}
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `pidfile` | yes | Path to PID file (plain integer) |

Output fields: `ok`, `pid`, `error`

---

### `log_fresh`

Checks that a log file's modification time is within a threshold. Optionally also searches the **last 8 KB** of the file for a regex pattern — useful for verifying that a periodic job left a success marker.

```json
{
  "name":        "email-sync",
  "type":        "log_fresh",
  "interval":    1800,
  "log":         "~/logs/email_sync.log",
  "max_age_min": 90
}
```

```json
{
  "name":      "backup-b2",
  "type":      "log_fresh",
  "interval":  86400,
  "log":       "~/logs/backup.log",
  "pattern":   "B2.*OK",
  "max_age_h": 25
}
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `log` | yes | Path to log file |
| `max_age_h` | one of these | Fail if mtime older than N hours |
| `max_age_min` | one of these | Fail if mtime older than N minutes |
| `pattern` | no | Regex; fail if not found in last 8 KB |

When `pattern` is given without a max_age threshold, only the regex is checked (mtime age is still reported).

Output fields: `ok`, `age_h`, `age_min`, `error`

---

### `status_file`

Reads a JSON status file and checks two things independently:

1. **Age** — the file's mtime (or an embedded `ts` field in ISO 8601) must be within `max_age_h`
2. **Status** — a `status` or `ok` field must indicate success

```json
{
  "name":      "burlak",
  "type":      "status_file",
  "interval":  3600,
  "path":      "~/.config/burlak/last_run.json",
  "max_age_h": 12
}
```

The `status` field is considered ok if its value is `"success"`, `"ok"`, or `"healthy"`. A boolean `ok` field is also accepted. If neither field exists, the check passes (age-only).

| Parameter | Required | Description |
|-----------|----------|-------------|
| `path` | yes | Path to JSON status file |
| `max_age_h` | no | Fail if file (or embedded `ts`) is older than N hours |

Output fields: `ok`, `age_h`, `last_status`, `error`

---

## Output format

`system_pulse.json` is written atomically (write to temp, rename) on every run:

```json
{
  "checked_at": "2026-04-17T10:30:00Z",
  "checks": {
    "ollama":        { "ok": true,  "latency_ms": 42,   "checked_at": "2026-04-17T10:30:00Z" },
    "nanoclaw":      { "ok": true,  "pid": 12345,       "checked_at": "2026-04-17T10:30:00Z" },
    "email-sync":    { "ok": true,  "age_min": 12.3,    "checked_at": "2026-04-17T10:25:00Z" },
    "backup-b2":     { "ok": false, "age_h": 27.1, "error": "log stale: 27h (max 25h)", "checked_at": "2026-04-17T06:00:00Z" },
    "burlak":        { "ok": true,  "age_h": 2.1, "last_status": "success", "checked_at": "2026-04-17T10:00:00Z" }
  }
}
```

The top-level `checked_at` reflects the time of the most recent health-monitor invocation. Each individual check's `checked_at` is when that check last ran (may be older if its interval hasn't elapsed).

**Important:** `system_pulse.json` always contains all checks — including those that weren't due this cycle. A check not due this run retains its previous result. Staleness for individual checks should be inferred from the per-check `checked_at` field.

---

## Transition log

`health_pulse.log` is append-only. A line is written whenever a check flips state (ok → fail, fail → ok), on first run, or once per hour while a check stays DOWN (so the log doesn't go silent for hours during a long outage):

```
2026-04-17T10:30:00Z [INIT]  ollama: ok (42 ms)
2026-04-17T11:05:00Z [DOWN]  ollama (Connection refused)
2026-04-17T12:05:00Z [STILL] ollama (down 1.0h) (Connection refused)
2026-04-17T13:05:00Z [STILL] ollama (down 2.0h) (Connection refused)
2026-04-17T13:30:00Z [UP  ]  ollama (38 ms)
2026-04-17T10:30:00Z [INIT]  backup-b2: FAIL – log stale: 27h (max 25h)
```

`[STILL]` lines are emitted no more than once per hour per check. The interval is hard-coded in `Runner.swift` (`stillDownInterval`).

---

## State persistence

`pulse_state.json` is written after each invocation. It records `lastRun` and `lastResult` for every check. On the next invocation, checks that haven't elapsed their interval are skipped.

When the config changes (checks added or removed), `pulse_state.json` is pruned to only the checks in the current config — stale entries from removed checks don't appear in `system_pulse.json`.

---

## launchd integration (macOS)

Create `~/Library/LaunchAgents/com.yourapp.health-monitor.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.yourapp.health-monitor</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/you/.local/bin/health-monitor</string>
    </array>
    <key>StartInterval</key>
    <integer>300</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/tmp/health-monitor-error.log</string>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/com.yourapp.health-monitor.plist
# verify
launchctl list | grep health-monitor
cat /tmp/health-monitor-error.log   # should be empty
```

`StartInterval: 300` runs health-monitor every 5 minutes. Because each run exits immediately after writing the status file, memory usage is negligible (< 10 MB for a few seconds per run).

---

## CLI reference

```
health-monitor [options]

Options:
  --config <path>   Config file (default: ~/.config/health-monitor/config.json)
  --output <path>   Status JSON path (overrides config; default: from config or ~/.config/health-monitor/system_pulse.json)
  --log <path>      Transitions log path (overrides config; default: from config or ~/.config/health-monitor/health_pulse.log)
  --once            Run all checks now regardless of per-check intervals
  --version         Print version and exit
  --help            Print this help and exit
```

`--once` is useful for testing: it ignores `pulse_state.json` intervals and forces all checks to run immediately.

---

## Troubleshooting

**health-monitor is not running**

```bash
launchctl list | grep health-monitor   # should show PID
cat /tmp/health-monitor-error.log      # stderr from last run
~/.local/bin/health-monitor --once     # run manually to see errors
```

**system_pulse.json is stale (older than ~10 min)**

launchd may have unloaded the agent. Re-load it:

```bash
launchctl load ~/Library/LaunchAgents/com.yourapp.health-monitor.plist
launchctl kickstart -k gui/$(id -u)/com.yourapp.health-monitor
```

**A check is always failing**

Run with `--once` to see the exact error:
```bash
~/.local/bin/health-monitor --once && cat ~/.config/health-monitor/system_pulse.json | python3 -m json.tool
```

**Binary not visible in FDA list**

You must code-sign with an Apple Developer certificate. Run `security find-identity -v -p codesigning` to list available identities, then re-sign.

---

## Adding a new check type

1. Add parameters to `CheckConfig` in `Sources/health-monitor/Models.swift`
2. Add a case + implementation function in `Sources/health-monitor/Checks.swift`
3. Wire it in the `switch` in `runCheck()` in `Checks.swift`
4. Update `pulse_config.example.json`
5. `swift build -c release && cp .build/release/health-monitor ~/.local/bin/health-monitor`

The implementation function receives a `CheckConfig` and returns a `CheckResult`. For async I/O use `async` and `URLSession`; for synchronous operations (file system, process signals) use `Foundation` directly.

---

## Project structure

```
Sources/health-monitor/
├── Entry.swift     — @main entry point, wraps runMain() in async context
├── Runner.swift    — CLI arg parsing, config/state loading, main loop, atomic writes
├── Checks.swift    — check implementations (http_ping, pid_alive, log_fresh, status_file)
└── Models.swift    — Codable data types (CheckConfig, CheckResult, SystemPulse, …)
```

---

## License

MIT
