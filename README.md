# health-monitor

Configurable macOS health monitor — Swift CLI, launchd-managed.

Runs a set of configurable health checks on a schedule and writes a JSON status file. Designed to be called periodically by launchd (every 5 minutes). Each check type has its own interval so expensive checks run less frequently than cheap ones.

## Features

- **JSON-configured** checks — no code changes to add or remove a check
- **Per-check intervals** — e.g. HTTP pings every 5 min, backup freshness once a day
- **State persistence** — only runs checks whose interval has elapsed; skips the rest
- **Transition log** — appends a timestamped line whenever a check flips UP↔DOWN
- **Concurrent execution** — due checks run in parallel via Swift structured concurrency
- **macOS-native binary** — visible by name in System Settings → Privacy & Security

## Installation

```bash
# Build
cd ~/Develop/health-monitor
swift build -c release

# Install
mkdir -p ~/.local/bin
cp .build/release/health-monitor ~/.local/bin/health-monitor

# Optional: sign so it appears by name in FDA list
codesign --sign "Apple Development: Your Name (TEAMID)" \
         --options runtime ~/.local/bin/health-monitor
```

## Configuration

Default config path: `~/.config/health-monitor/config.json`

```json
{
  "output": "~/.config/health-monitor/system_pulse.json",
  "log":    "~/.config/health-monitor/health_pulse.log",
  "checks": [
    {
      "name": "my-api",
      "type": "http_ping",
      "interval": 300,
      "url": "http://localhost:11434/api/tags",
      "timeout": 6
    }
  ]
}
```

See [`pulse_config.example.json`](pulse_config.example.json) for all check types and parameters.

## Check types

### `http_ping`

HTTP GET with latency measurement.

```json
{
  "name":     "ollama",
  "type":     "http_ping",
  "interval": 300,
  "url":      "http://10.0.10.70:11434/api/tags",
  "timeout":  6
}
```

Result fields: `ok`, `latency_ms`, `error`

### `pid_alive`

Reads a PID file and sends signal 0 to verify the process is running.

```json
{
  "name":    "myapp",
  "type":    "pid_alive",
  "interval": 300,
  "pidfile": "~/.run/myapp.pid"
}
```

Result fields: `ok`, `pid`, `error`

### `log_fresh`

Checks that a log file was modified recently. Optionally searches the last 8 KB for a regex pattern (useful for verifying a cron job completed successfully).

```json
{
  "name":        "backup",
  "type":        "log_fresh",
  "interval":    86400,
  "log":         "~/logs/backup.log",
  "max_age_h":   25,
  "pattern":     "Backup complete"
}
```

Parameters: `log` (required), `max_age_h` or `max_age_min` (one required), `pattern` (optional regex).

Result fields: `ok`, `age_h`, `error`

### `status_file`

Reads a JSON status file and checks two things:
1. The file (or an embedded timestamp field) is not older than `max_age_h`
2. A `status` or `ok` field indicates success

```json
{
  "name":      "burlak",
  "type":      "status_file",
  "interval":  3600,
  "path":      "~/.config/burlak/last_run.json",
  "max_age_h": 12
}
```

Result fields: `ok`, `age_h`, `last_status`, `error`

## Output format

`system_pulse.json`:

```json
{
  "checked_at": "2026-04-17T10:30:00Z",
  "checks": {
    "ollama": { "ok": true, "latency_ms": 42 },
    "burlak": { "ok": true, "age_h": 2.1 },
    "backup": { "ok": false, "age_h": 27.3, "error": "pattern not found" }
  }
}
```

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
```

## CLI reference

```
health-monitor [options]

Options:
  --config <path>   Config file (default: ~/.config/health-monitor/config.json)
  --output <path>   Status JSON output (overrides config)
  --log <path>      Transitions log (overrides config)
  --once            Run all checks now, ignore per-check intervals
  --version         Print version
  --help            Print this help
```

## License

MIT
