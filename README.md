# memscope

Memory census for the agent-era Mac. One shot, read-only, zero dependencies —
`ps`, `sysctl`, `memory_pressure`, `awk`.

Classic cleaners (CleanMyMac, Activity Monitor) see 60 anonymous `node`
processes and shrug. Developer machines in 2026 run fleets of MCP servers,
agent sessions, dev servers, and half a dozen private Chromiums (every
Electron app ships one). memscope understands that workload.

## What it reports

- **System pressure** — RAM vs. real demand (resident + swap), compressor and
  pagein totals since boot, and an honest verdict: hygiene problem or
  structural gap.
- **Census by family** — Chrome / Electron apps / node-agents / Java / Python /
  databases / macOS system, so you see who actually eats what.
- **Chrome renderers** — top tabs by memory with age (long-lived SPA tabs leak).
- **Electron fleet** — every app bundle running its own private Chromium,
  flagged `[Electron]`.
- **Node / agent sprawl** — MCP servers, dev servers, watchers; total plus top
  consumers.
- **Duplicate connectors** — every open agent session spawns its own copy of
  every MCP server; see the multiplication.
- **Orphaned MCP trees** — sessions that died and leaked their connectors to
  launchd (ppid 1, >24h). Prints ready-made `kill` lines; never kills anything
  itself.

## Usage

```bash
./memscope.sh                    # colorized report
./memscope.sh --no-color         # plain (for logs/pipes)
./memscope.sh --top 15           # deeper top-N lists
./memscope.sh guard --dry-run    # show what a guard pass would reap
./memscope.sh guard              # one guard pass now
./memscope.sh install-guard      # launchd agent: guard every 2 min
./memscope.sh uninstall-guard
./memscope.sh status             # guard performance: passes, reaps, swap sparkline
./memscope.sh menubar            # SwiftBar/xbar plugin output
```

## Observability

Every guard pass appends a JSONL line to `~/.memscope/metrics.jsonl`
(`ts, pressure level, swap_pct, resident_gb, trees reaped, MB freed`) and
actions go to `~/.memscope/guard.log`. `status` summarizes the last 24h with
a swap-trend sparkline:

```
passes: 720   orphan trees reaped: 41   freed: 575 MB   pressure alerts: 3
swap now 55%   min 52%   max 91%
swap trend: ▇▇▇█▅▄▄▄▃▃▃▃
```

## Menubar UI (no Electron, obviously)

Install [SwiftBar](https://swiftbar.app) (or xbar), then:

```bash
mkdir -p ~/SwiftBar && printf '#!/bin/bash\nexec %s menubar\n' "$PWD/memscope.sh" > ~/SwiftBar/memscope.2m.sh && chmod +x ~/SwiftBar/memscope.2m.sh
```

You get a live 🧠 swap% in the menubar (⚠️ ≥70%, 🔴 ≥90%), with a dropdown
showing resident/swap, today's reap totals, and one-click "Reap orphans now"
/ "Full census" actions. A memory tool that shipped its own Chromium to
draw a number would be self-parody; the entire UI is this script's stdout.

## Guard mode (preemptive free-up)

The guard runs every 2 minutes and works ahead of the macOS
"out of application memory" force-quit dialog:

1. **Always reaps provable garbage** — orphaned MCP connector trees left
   behind by dead agent sessions (ppid 1, alive >24h). These pin swap even
   while idle; reaping them on this machine released ~4 GB of swap.
2. **Under pressure** (kernel pressure level ≥ warn, or swap ≥ 85%) it sends
   a macOS notification naming the biggest consumers (Chrome tabs, Electron
   apps) so you can close things *before* the OOM dialog picks for you.
3. **Idle-session auto-close** — a Claude Code session process that accrues
   under 10s of CPU across 6 continuous hours (`MEMSCOPE_IDLE_HOURS` to tune,
   `0` to disable) is provably unread; the guard sends it SIGTERM and
   notifies. Transcripts live on disk and sessions resume from the app, so
   only warm state is lost. Each idle session holds ~450–550 MB (its process
   plus its private copy of every MCP connector). The guard never touches its
   own ancestor chain, and the idle clock resets on any CPU activity — a
   session running background work is never "idle".
4. **Never auto-kills anything with user state.** The kill allowlist is two
   provable classes: dead sessions' connector trees, and sessions with zero
   CPU activity for 6+ hours. Everything else is advice.
   Logs: `~/.memscope/guard.log`, metrics: `~/.memscope/metrics.jsonl`.

## Proving it works

```bash
./test/run_tests.sh
```

Nine assertions, no root, no side effects, ~5 seconds:

- **Unit** — the orphan detector runs against a canned process table
  (`MEMSCOPE_PS_FIXTURE`): kills the >2h orphan tree and the 26h one, spares
  the live-parented connector, the young orphan, and memscope itself.
- **Integration** — a fake session process (path-matched to the real pgrep
  pattern) with a seeded idle clock really receives SIGTERM
  (`MEMSCOPE_IDLE_SECONDS` shrinks 6h to 60s for the test), and the close is
  logged; a fresh session is only tracked, never killed.
- **Production evidence** — every real action is in `~/.memscope/guard.log`
  and every pass in `metrics.jsonl`; `status` renders the before/after. On
  this machine's first real pass: 41 orphaned trees reaped, swap 91% → 55%.

## Design principles

- **Read-only.** Suggests kill commands, never executes them.
- **No dependencies.** macOS built-ins only; single file.
- **Honest verdicts.** If demand exceeds RAM structurally, it says "no amount
  of cleanup closes this" instead of selling you a cleanup.

## Sample finding (real, first run)

```
Orphaned MCP trees (session is gone; connectors leaked):
   25 MB  kill 80839 81075  # up 02-22:45:36 mcp-mongo-server
   ...
41 orphaned trees, ~611 MB reclaimable.
```

41 dead agent sessions had leaked their MongoDB connectors for up to 3 days.
No existing tool looks for this.
