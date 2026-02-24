[repo]: https://github.com/johnzfitch/claude-warden
[usage-helper]: https://github.com/johnzfitch/claude-usage-helper
[hooks-docs]: https://docs.anthropic.com/en/docs/claude-code/hooks
[claude-code]: https://docs.anthropic.com/en/docs/claude-code
[token-api]: https://docs.anthropic.com/en/docs/build-with-claude/token-counting

# claude-warden

Token-saving hooks + observability for [Claude Code][claude-code]. Prevents verbose output, blocks binary reads, enforces subagent budgets, truncates large outputs, and provides a rich statusline &mdash; saving thousands of tokens per session.

Pair with [claude-usage-helper][usage-helper] for budget tracking, cost telemetry, and session analytics. Warden enforces; usage-helper accounts.

## Quickstart

1. Install prerequisites: `jq` (required). Optional: `rg`, `fd`, `budget-cli`.
2. Install hooks into `~/.claude/` (symlink mode):
   ```bash
   ./install.sh
   ```
3. Start a new Claude Code session. Hooks run automatically.

Dry-run (no changes to `~/.claude/`):

```bash
./install.sh --dry-run
```

## Architecture

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/architecture-dark.png">
  <source media="(prefers-color-scheme: light)" srcset="assets/architecture-light.png">
  <img alt="Architecture: claude-warden (enforcement) feeds into claude-usage-helper (accounting) in a closed loop" src="assets/architecture-dark.png" width="800">
</picture>

## What it does

claude-warden installs a set of shell hooks that intercept Claude Code tool calls at every stage of execution. Each hook enforces token-efficient patterns and blocks common waste.

### Guard catalog

| Hook | Event | What it guards |
|---|---|---|
| `pre-tool-use` | PreToolUse | Blocks verbose commands (`npm install` without `--silent`, `cargo build` without `-q`, `pip install` without `-q`, `curl` without `-s`, `wget` without `-q`, `docker build/pull` without `-q`). Blocks binary file reads. Enforces subagent tool budgets. Blocks recursive grep/find without limits. Blocks Write >100KB, Edit >50KB. Blocks minified file access. |
| `post-tool-use` | PostToolUse | Strips `<system-reminder>` blocks from all tool results. Compresses Task/agent output >6KB to structured lines (bullets, headers, tables). Truncates Bash output >20KB to 10KB (8KB head + 2KB tail). Suppresses output >500KB entirely. Detects binary output via <abbr title="POSIX octal dump, no grep -P dependency">od</abbr>. Tracks session stats. Budget alerts at 75%/90%. |
| `read-guard` | PreToolUse (Read) | Blocks Read on bundled/generated files (`node_modules/`, `/dist/`, `.min.js`, etc.). Blocks files >2MB. Reports blocked reads to events.jsonl. |
| `read-compress` | PostToolUse (Read) | Strips `<system-reminder>` blocks from Read results. Extracts structural signatures (imports, functions, classes) from large file reads. Subagents: >100 lines. Main agent: >500 lines. Reports compression savings to events.jsonl. |
| `permission-request` | PermissionRequest | Auto-denies dangerous commands (`rm -rf /`, `mkfs`, `curl \| bash`). Auto-allows safe read-only commands. |
| `stop` | Stop | Logs session stop events with duration. |
| `session-lifecycle` | SessionStart / SessionEnd | Initializes session timing and budget snapshots. Logs session duration, budget delta, subagent counts. |
| `subagent-start` | SubagentStart | Enforces budget-cli limits. Tracks active subagent count. Injects type-specific guidance with output budgets (max token counts, format constraints). |
| `subagent-stop` | SubagentStop | Reclaims budget. Logs subagent metrics (duration, type, worktree). |
| `tool-error` | PostToolUseFailure | Logs errors with context. Provides recovery hints. |
| `statusline.sh` | StatusLine | Displays model, context %, IO tokens, cache stats, tool count, hottest output, active subagents, budget utilization. |

### Hook lifecycle

```
PreToolUse ──> [tool executes] ──> PostToolUse
     │                                  │
     ├─ pre-tool-use (all tools)        ├─ post-tool-use (all tools)
     └─ read-guard (Read only)          └─ read-compress (Read only)
```

## Requirements

<dl>
  <dt><strong>Required</strong></dt>
  <dd><code>jq</code> &mdash; JSON processing</dd>
  <dt><strong>Recommended</strong></dt>
  <dd><code>rg</code> (ripgrep), <code>fd</code> (fd-find)</dd>
  <dt><strong>Optional</strong></dt>
  <dd><code>budget-cli</code> &mdash; token budget tracking, from <a href="https://github.com/johnzfitch/claude-usage-helper">claude-usage-helper</a></dd>
  <dd><code>python3</code> with <code>anthropic</code> package &mdash; exact token counting via API (see <a href="#token-savings-accounting">Token savings accounting</a>)</dd>
  <dd><code>mitmdump</code> &mdash; only for the <a href="#api-capture">API capture</a> tool</dd>
</dl>

## Install

### Quick install (latest release)

```bash
curl -fsSL https://raw.githubusercontent.com/johnzfitch/claude-warden/master/install-remote.sh | bash
```

The remote installer downloads a release tarball, verifies its SHA-256 checksum (hard-fails if missing), validates tarball contents, then runs `install.sh --copy`.

To pin a version:

```bash
curl -fsSL https://raw.githubusercontent.com/johnzfitch/claude-warden/master/install-remote.sh | bash -s -- v0.2.0
```

### Install from source (development)

```bash
git clone https://github.com/johnzfitch/claude-warden.git ~/dev/claude-warden
cd ~/dev/claude-warden
./install.sh
```

### Install modes

**Symlink** (default) &mdash; edits to the repo take effect immediately:

```bash
./install.sh
```

**Copy** &mdash; files are independent of the repo:

```bash
./install.sh --copy
```

**Dry run** &mdash; see what would happen:

```bash
./install.sh --dry-run
```

### What install.sh does

1. Checks prerequisites (`jq` required, warns if `rg`/`fd` missing)
2. Detects platform (Linux, macOS, WSL)
3. Backs up existing `~/.claude/hooks/` and `~/.claude/settings.json`
4. Symlinks (or copies) all hook scripts to `~/.claude/hooks/`
5. Symlinks (or copies) `statusline.sh` to `~/.claude/statusline.sh`
6. Merges hook config into `~/.claude/settings.json` (preserves your permissions, plugins, model, etc.)
7. Sets executable permissions
8. Validates JSON and shell syntax

## Uninstall

```bash
./uninstall.sh
```

Restores your most recent settings.json backup. Hook backups remain in `~/.claude/hooks.bak.*/`.

## Configuration

### Tuning thresholds

Edit the hook scripts directly (in symlink mode, edit the repo files):

- **Output truncation**: `post-tool-use` &mdash; `WARDEN_TRUNCATE_BYTES` (default 20KB)
- **Read compression**: `read-compress` &mdash; subagent threshold at 100 lines, main agent at 500 lines
- **File size limit**: `read-guard` &mdash; `MAX_SIZE_MB=2`
- **Subagent budgets**: `pre-tool-use` &mdash; `BUDGET_LIMITS` associative array
- **Binary detection**: `post-tool-use` &mdash; POSIX `od` + `grep` for NUL bytes (full-stream scan)

### Token savings accounting

All hooks report token savings to `~/.claude/.statusline/events.jsonl` using the standard warden event schema. By default, token counts are estimated at ~3.5 bytes/token (benchmarked against Claude's tokenizer across code, prose, and structured output).

For exact counts, set the `WARDEN_TOKEN_COUNT` environment variable:

```bash
export WARDEN_TOKEN_COUNT=api
```

When enabled, each truncation event spawns a background process that calls the [Anthropic token counting API][token-api] (free, separate rate limits) and appends a correction event to events.jsonl. The hook returns immediately &mdash; zero added latency.

Requirements for API mode:
- `ANTHROPIC_API_KEY` in environment (set automatically by Claude Code)
- `python3` with the `anthropic` package installed

If `python3` on your PATH doesn't have `anthropic`, set `WARDEN_PYTHON` to one that does:

```bash
export WARDEN_PYTHON=/path/to/venv/bin/python3
```

Graceful degradation: if the API key is missing, `anthropic` isn't installed, or the network is unavailable, the background process silently exits and the estimate stands.

### Disabling specific guards

To disable a specific guard category, remove or comment out the corresponding matcher in `settings.hooks.json` and re-run `./install.sh`. For example, to disable read compression:

```json
// Remove or comment this block from settings.hooks.json:
{
  "matcher": "Read",
  "hooks": [{"type": "command", "command": "$HOME/.claude/hooks/read-compress", "timeout": 7}]
}
```

### Adding your own permission allow-list

The `permission-request` hook handles auto-deny/allow. For tools you use frequently, add them to the `permissions.allow` array in `~/.claude/settings.json`:

```json
{
  "permissions": {
    "allow": [
      "Bash(rg:*)",
      "Bash(fd:*)",
      "Bash(git status:*)"
    ]
  }
}
```

Commands in the allow-list never reach the permission hook.

## Platform support

| Platform | Status | Notes |
|---|---|---|
| Linux | Full support | Primary development platform |
| macOS | Full support | Uses `gtimeout` fallback, `osascript` for notifications, macOS `stat` flags |
| WSL | Full support | Detected via `/proc/version` |

### Cross-platform details

- **`timeout`**: Falls back to `gtimeout` (coreutils), then no-timeout
- **`stat`**: Uses `-c%s` (Linux) with `-f%z` (macOS) fallback
- **`flock`**: Replaced with `mkdir`-based locking (atomic on all POSIX)
- **`notify-send`**: Falls back to `osascript` (macOS), silently skips if neither available
- **`rg`**: Falls back to `grep` where used
- **Binary detection**: Uses `od -An -tx1 | grep ' 00'` (POSIX, works on macOS/Linux/BSD)

## Monitoring stack

Warden includes an optional observability stack in `monitoring/` that persists hook events, measures per-tool latency, and emits OTLP trace spans.

### Components

| Service | Image | Port | Purpose |
|---|---|---|---|
| Loki | `grafana/loki:3.4.2` | 3100 | Log aggregation (30-day retention, TSDB filesystem storage) |
| <abbr title="OpenTelemetry">OTEL</abbr> Collector | `otel/opentelemetry-collector-contrib` | 4317/4318 | Receives OTLP logs + traces, tails `events.jsonl`, exports to Loki + Tempo |
| Prometheus | `prom/prometheus` | 9090 | Metrics (Claude Code OTLP metrics + node-exporter textfiles) |
| Node Exporter | `prom/node-exporter` | 9101 | Textfile collector for `budget-cli` metrics |
| Tempo | `grafana/tempo:2.7.2` | 3200/3205 | Distributed trace storage and visualization |
| Grafana | `grafana/grafana` | 3000 | Dashboards (admin/admin) |

### Setup

**Linux** (uses `network_mode: host`):

```bash
cd monitoring && docker compose up -d
```

**macOS / Docker Desktop** (uses bridge networking with service DNS):

```bash
cd monitoring && docker compose -f docker-compose.yml -f docker-compose.macos.yml up -d
```

> [!NOTE]
> Docker Desktop does not support `network_mode: host`. The macOS override switches to bridge networking and mounts config overrides that replace `localhost` references with Docker service names (`loki`, `prometheus`, `otel-collector`, etc.).

### Data flow

```
Claude Code ──OTLP──> OTEL Collector ──> Loki (logs)
                           │              Prometheus (metrics)
                           │              Tempo (traces)
                           │
hooks/events.jsonl ──filelog──> OTEL Collector ──> Loki

hooks/pre-tool-use  ──records start timestamp──>  state file
hooks/post-tool-use ──computes latency──> events.jsonl (tool_latency)
                    ──curl OTLP/HTTP──> OTEL Collector (trace span)
```

### Per-tool latency tracking

Every tool call gets wall-clock timing measured by the hooks:

1. `pre-tool-use` writes a nanosecond timestamp to `$STATE_DIR/.tool-start-$TOOL-$$`
2. `post-tool-use` reads it, computes `duration_ms`, emits a `tool_latency` event to `events.jsonl`
3. A trace span is fired to the OTEL collector via `hooks/lib/otel-trace.sh` (fire-and-forget curl)

Latency events flow through the collector into Loki and are queryable via LogQL:

```
{service_name="claude-code"} | json | event_type="tool_latency" | duration_ms > 2000
```

### Trace spans

`hooks/lib/otel-trace.sh` emits one OTLP span per tool call to `localhost:4318/v1/traces`:

- **trace_id**: deterministic from session ID (md5, 32 hex chars)
- **span_id**: random 16 hex chars per call
- **parent_span_id**: deterministic root span from session ID
- Attributes: `tool.name`, `tool.command` (first 200 chars), `tool.output_bytes`, `tool.duration_ms`

Traces are stored in Tempo and can be explored in Grafana via the Tempo datasource. Loki log entries link to traces via the `trace_id` derived field.

### Dashboards

Four provisioned dashboards in `monitoring/grafana/dashboards/`:

| Dashboard | UID | What it shows |
|---|---|---|
| Working Dashboard | `claude-code-otel` | Cost, tokens, budget utilization, session duration, API metrics (Prometheus) |
| Tool Latency & Traces | `warden-tool-latency` | Latency scatter plot, per-tool avg/p95/max, call frequency, slow call table, event log, trace span rate, output correlation, tokens saved by rule, event type distribution (Loki) |
| Output Size & Tokens | `warden-output-size` | Per-tool output bytes, estimated tokens, large output table, cumulative token trend, line count distribution, unbounded read detection (Loki) |
| Subagent & Session Lifecycle | `warden-subagent-lifecycle` | Subagent duration by type, session stop reasons, agent type distribution, blocked events by rule, worktree tracking (Loki) |

The latency and output-size dashboards include session and tool filter variables. Tool filtering operates on parsed JSON fields (not stream labels) since only `session_id` is a Loki index label.

### Verification

```bash
# Loki healthy
curl -s http://localhost:3100/ready

# Query tool latency events
curl -sG http://localhost:3100/loki/api/v1/query_range \
  --data-urlencode 'query={service_name="claude-code"} | json | event_type="tool_latency"' \
  --data-urlencode 'limit=5' \
  --data-urlencode "start=$(date -d '1 hour ago' +%s)" \
  --data-urlencode "end=$(date +%s)"

# Check trace spans in Tempo
curl -s http://localhost:3200/ready

# Check latency events in events.jsonl
grep tool_latency ~/.claude/.statusline/events.jsonl | tail -5
```

## API capture

The `capture/` directory contains a <abbr title="man-in-the-middle">MITM</abbr> proxy wrapper for recording full Claude Code API traffic.

```bash
capture/claude                          # interactive session
capture/claude -p "prompt"             # non-interactive
```

Logs land in `~/claude-captures/YYYY-MM-DD/capture-HHMMSS.jsonl`. Each line is a JSON record: `stream_start`, `stream_chunk`, `stream_end` (for SSE), or `exchange` (for non-streaming).

> [!IMPORTANT]
> Request and response bodies are **truncated to 200 characters by default**. To enable full body capture, set `WARDEN_CAPTURE_BODIES=1`. Even with full capture enabled, sensitive JSON keys (`system`, `messages`) are redacted.

<dl>
  <dt>Prerequisites</dt>
  <dd><code>mitmdump</code> (from <code>mitmproxy</code>) and a trusted CA cert at <code>~/.mitmproxy/mitmproxy-ca-cert.pem</code></dd>
  <dt>Log permissions</dt>
  <dd>Capture JSONL files and the proxy log (<code>~/.claude/capture-mitm.log</code>) are created with mode <code>600</code></dd>
  <dt>Header scrubbing</dt>
  <dd><code>x-api-key</code>, <code>authorization</code>, and <code>proxy-authorization</code> headers are redacted in both streaming and non-streaming paths</dd>
</dl>

## Project layout

| Path | Purpose |
|---|---|
| `hooks/` | Claude Code hook scripts (bash) |
| `hooks/lib/common.sh` | Shared library: input parsing, event emission, latency tracking, cross-platform shims |
| `hooks/lib/otel-trace.sh` | Lightweight OTLP/HTTP trace span emitter (bash + curl) |
| `capture/` | MITM proxy wrapper + mitmproxy addon for API traffic capture |
| `statusline.sh` | Claude Code statusline script (bash) |
| `settings.hooks.json` | Hook + statusline configuration template merged into `~/.claude/settings.json` |
| `install.sh` | Installs hooks + statusline into `~/.claude/` (symlink or copy) and merges settings |
| `install-remote.sh` | Downloads a release tarball, verifies checksum, runs `install.sh --copy` |
| `uninstall.sh` | Removes installed hooks/statusline and restores the most recent settings backup |
| `monitoring/` | Docker Compose observability stack (Loki, OTEL Collector, Prometheus, Tempo, Grafana) |
| `monitoring/docker-compose.macos.yml` | Bridge networking override for Docker Desktop (macOS/Windows) |
| `monitoring/grafana/` | Grafana provisioning (datasources, dashboards) |
| `tests/` | Fixture-driven test harness (`bash tests/run.sh`) |
| `.github/workflows/release.yml` | GitHub Actions workflow: builds tarball + checksum on tag push |
| `VERSION` | Current release version |
| `assets/` | README images (architecture diagram) |
| `demo/mock-inputs/` | Small, committed JSON fixtures for exercising hooks locally |

## How it works

Claude Code supports [hooks][hooks-docs] &mdash; shell commands that run at specific points in the tool-use lifecycle. Hooks receive JSON on stdin describing the tool call and can:

- **Exit 0**: Allow the tool call (optionally with `{"suppressOutput":true}`)
- **Exit 2**: Block the tool call (stderr message is fed back to Claude as feedback)
- **Output JSON**: Modify tool output (`{"modifyOutput":"..."}`) or suppress it

claude-warden hooks are pure bash with a single dependency (`jq`). They run in milliseconds and add negligible latency to tool calls. All paths use `$HOME` for portability &mdash; no hardcoded user directories. Every filtering decision (block, truncate, compress, strip) is logged to `~/.claude/.statusline/events.jsonl` with token savings estimates for downstream consumers.

## Testing

Run the test harness:

```bash
bash tests/run.sh
```

It runs shell syntax checks, validates JSON fixtures, and executes fixture-driven behavioral assertions covering pre-tool-use blocking/allow, post-tool-use output tracking/truncation, read-compress, permission-request, and statusline rendering.

<details>
<summary>Manual checks</summary>

```bash
# Shell syntax
find hooks -maxdepth 1 -type f ! -name '_token-count-bg' -print0 | xargs -0 bash -n
bash -n install.sh uninstall.sh statusline.sh

# Optional: validate the Python helper used only for API token counting mode
command -v python3 >/dev/null 2>&1 && python3 -m py_compile hooks/_token-count-bg

# JSON validity
jq . settings.hooks.json >/dev/null

# Exercise post-tool-use fixture (system reminder stripping)
cat demo/mock-inputs/post-tool-use-reminder-bash.json | hooks/post-tool-use | jq -r '.modifyOutput'
```

</details>

## Troubleshooting

<details>
<summary>Hooks don't seem to run</summary>

1. Confirm `~/.claude/settings.json` contains the `hooks` configuration (install merges `settings.hooks.json`).
2. Start a fresh Claude Code session after installing.
3. If a command is in your `permissions.allow` list, it will not reach the `permission-request` hook.

</details>

<details>
<summary>Read is being blocked unexpectedly</summary>

`read-guard` blocks common bundled/generated patterns (`node_modules/`, `dist/`, minified JS) and blocks files larger than 2MB. Search for the original source file or use a bounded read (smaller slices).

</details>

<details>
<summary>macOS Docker Desktop networking issues</summary>

The base `docker-compose.yml` uses `network_mode: host`, which Docker Desktop does not support. Use the macOS override:

```bash
docker compose -f docker-compose.yml -f docker-compose.macos.yml up -d
```

This switches to bridge networking and mounts config files that replace `localhost` with Docker service DNS names.

</details>

## Contributing

See `CONTRIBUTING.md`.

## Security

See `SECURITY.md` for security assumptions, data handling notes, and reporting guidance.

## Related

| Project | What it does |
|---|---|
| [claude-usage-helper][usage-helper] | Budget tracking, context compression, cost telemetry. Provides `budget-cli` that warden hooks call for budget enforcement. |

## License

MIT
