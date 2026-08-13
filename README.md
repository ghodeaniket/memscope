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
./memscope.sh              # colorized report
./memscope.sh --no-color   # plain (for logs/pipes)
./memscope.sh --top 15     # deeper top-N lists
```

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
