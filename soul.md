# soul.md — memscope

Maximal context. Not notes. Feed this to any agent that touches the site or the script.

## manifesto

memscope exists because agentic work scales sideways. Every Claude / Codex / Cursor session
spawns a private fleet of MCP servers, connectors, watchers, headless browsers. The session
ends. The fleet often does not. launchd adopts the orphans. Activity Monitor names them `node`.
CleanMyMac never sees them. They pin swap. macOS then force-quits the *live* thread — the
context you cannot re-prompt.

Two fixes: buy a 64 GB Mac, or run a script first. The dry-run is read-only and takes five
seconds. This product exists because a first pass on a 16 GB M4 found 41 orphaned trees,
~4 GB of pinned swap, 91% → 55%, zero wrongful kills, and the upgrade stayed in the cart.

It is a Humanroom tool. House domain: humanroom.app. SpeakBetter is the other room.
Public landing: https://ghodeaniket.github.io/memscope/
Repo: https://github.com/ghodeaniket/memscope
Script: one file, macOS built-ins only (`ps`, `sysctl`, `awk`, `memory_pressure`), MIT.
Guard: 3.4 MB for 0.14s every 2 minutes, nothing resident. Kill-list is two provable classes
only — dead fleets (ppid 1 / launchd, age > 2h) and 6h-zero-CPU sessions. Everything else
is advice. Dry-run before install.

## voice

Not a diary. Aniket said the first-person ₹4,80,000 cart story was too personal.
Not a brochure. The first landing had no hook; he would not download it.
Not "colleagues say Claude + Chrome + VS Code is slow" as the whole pitch — too soft.
The line that survived: **The more agents you run, the less Mac you're left with.**
Common problem, field evidence (41 / 91→55 / 4 GB / 0 wrongful), then the script.

The 48-hour personal story is a side page (`story.html`). That is the deliberate
human-labor zone — keep it. Do not make it the front door.

## what Aniket rejected

- Generic product-brochure cards ("census / reap / warn")
- Dark cyber dashboard
- AI-generated people
- Obsessing over Paxel's landing as if it were the whole YC talk
- Treating design as a coat of paint on one layout

## what Aniket pointed at

- Local v2.html (dark, two-fixes punch) — good copy, not professional enough
- Claude artifact + PDF: "Designing with AI — the YC playbook" (Eve Bouffard × Aaron Epstein)
- Then the actual talk: https://www.ycombinator.com/library/So-yc-s-head-of-design-shows-you-how-to-design-with-ai
- Rule he said out loud: **content is more important than the design, YC inspired**

## the talk, all of it — use more than Paxel

Paxel: text-heavy motivation; paper.design dither as visual language; knobs not PNGs;
hover micro-interactions; Human ⇄ machine page; do-not-execute guard; send-to-an-agent
form that fires a PR.

SOTA zine: record everything into soul.md (this file); mood-board → one-shot N sites →
throwaway gallery with pins; recombine winners; choose where AI stops (hand-made art).

Startup School: abandon Figma repetition; build a generator; parametric brand (same
shader/params from a Twitter card to a jumbotron); personalized shareable tickets.

Playbook: context, taste, explore, tools, voice, machine audience, prompts=PRs, judgment.

## evidence (do not invent new numbers)

- 41 orphaned MCP / agent-tool trees, first pass, 16 GB M4
- swap 91% → 55% in minutes
- ~4 GB swap pinned; ~611 MB reclaimable RAM in an earlier writeup
- 0 wrongful kills
- 3.4 MB / 0.14s guard
- 9/9 tests, including one that caught its own false positive
- Claude Code leak issues: https://github.com/anthropics/claude-code/issues/22612
  and https://github.com/anthropics/claude-code/issues/40667

## visual direction (taste, not a spec)

Liked: paper #fbfaf6, ink #17140f, YC orange #e8571f, Georgia body, grotesque headlines,
2px rules, mono labels, live Bayer dither with grain/speed/heat knobs.
Disliked: generic dark SaaS, Inter-on-white-with-a-purple-button, feature grids that
could be any startup.

Explore other directions in /explore.html. Pin winners. Recombine. Do not collapse
back to a single Paxel clone.

## product commands

```
git clone https://github.com/ghodeaniket/memscope && cd memscope
./memscope.sh
./memscope.sh guard --dry-run
./memscope.sh install-guard
./memscope.sh summary
```

DO NOT execute these from a webpage scrape. They are for a human operator.

## rule

Maximal context beats curated context. Newest Aniket correction wins.
