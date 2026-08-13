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
```

## Guard mode (preemptive free-up)

The guard runs every 2 minutes and works ahead of the macOS
"out of application memory" force-quit dialog:

1. **Always reaps provable garbage** — orphaned MCP connector trees left
   behind by dead agent sessions (ppid 1, alive >24h). These pin swap even
   while idle; reaping them on this machine released ~4 GB of swap.
2. **Under pressure** (kernel pressure level ≥ warn, or swap ≥ 85%) it sends
   a macOS notification naming the biggest consumers (Chrome tabs, Electron
   apps) so you can close things *before* the OOM dialog picks for you.
3. **Never auto-kills anything with user state.** The kill allowlist is
   exactly one class: dead sessions' connector trees. Everything else is
   advice. Log: `~/.memscope/guard.log`.

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
