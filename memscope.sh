#!/bin/bash
# memscope — memory census + pressure guard for the agent-era Mac
# What's actually eating your RAM: Chromium fleet, Electron apps, node/MCP
# sprawl, zombie dev processes.
#
# Usage:
#   memscope.sh [report] [--top N] [--no-color]   read-only census (default)
#   memscope.sh guard [--dry-run]                 one guard pass: reap orphaned
#                                                 MCP trees; under pressure,
#                                                 notify with specific advice
#   memscope.sh receipt [--reap]                  the story: N apps using X GB,
#                                                 which trees are already dead,
#                                                 and what a reap gives back
#   memscope.sh status | summary [DATE]           guard performance / daily rollup
#   memscope.sh install-guard                     launchd agent, every 2 min
#   memscope.sh uninstall-guard
#
# Guard safety rule: auto-kills ONLY provable garbage — connector trees whose
# parent session is dead (ppid=1, alive >24h, args mention mcp). Everything
# else is a notification, never a kill.

set -u

MODE="report"
case "${1:-}" in
  guard|install-guard|uninstall-guard|report|status|menubar|summary|receipt) MODE="$1"; shift ;;
esac

LOG_DIR="${MEMSCOPE_LOG_DIR:-$HOME/.memscope}"   # override for tests
GUARD_LOG="$LOG_DIR/guard.log"
PLIST="$HOME/Library/LaunchAgents/com.memscope.guard.plist"
LABEL="com.memscope.guard"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# Colors + rule, defined before mode dispatch so every subcommand can use them.
case " $* " in *" --no-color "*) _C=0 ;; *) [ -t 1 ] && _C=1 || _C=0 ;; esac
if [ "$_C" = 1 ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; YEL=$'\033[33m'
  GRN=$'\033[32m'; CYN=$'\033[36m'; R=$'\033[0m'
else
  B=""; DIM=""; RED=""; YEL=""; GRN=""; CYN=""; R=""
fi
hr() { printf '%s\n' "${DIM}────────────────────────────────────────────────────────────${R}"; }

# Process-table source: real ps, or a canned fixture for unit tests
ps_snapshot() {
  if [ -n "${MEMSCOPE_PS_FIXTURE:-}" ]; then cat "$MEMSCOPE_PS_FIXTURE"
  else ps -Axo pid=,ppid=,etime=,rss=,args=; fi
}

# Physical footprint per pid (what Activity Monitor calls "Memory"): resident +
# compressed + swapped. ps RSS counts only resident pages, so on a machine that
# is swapping — exactly memscope's target — RSS under-reports by orders of
# magnitude (observed 5,393 MB actual vs 10 MB RSS). Emits "pid KB".
footprint_map() {
  top -l 1 -n 9999 -stats pid,mem 2>/dev/null | awk '
  $1 ~ /^[0-9]+$/ && $2 != "" {
    v=$2; sub(/[+-]$/,"",v)
    unit=substr(v,length(v),1); num=substr(v,1,length(v)-1)+0
    if      (unit=="G") kb=num*1048576
    else if (unit=="M") kb=num*1024
    else if (unit=="K") kb=num
    else if (unit=="B") kb=num/1024
    else                kb=v+0
    printf "%s %d\n", $1, kb
  }'
}

# Process table with field 4 = physical footprint (KB) instead of RSS.
# Falls back to ps RSS for any pid top did not report, and entirely when a
# test fixture is supplying the table.
mem_snapshot() {
  if [ -n "${MEMSCOPE_PS_FIXTURE:-}" ] || [ -n "${MEMSCOPE_NO_FOOTPRINT:-}" ]; then
    ps_snapshot; return
  fi
  awk 'NR==FNR { fp[$1]=$2; next }
       { if ($1 in fp) $4 = fp[$1]; print }' \
      <(footprint_map) <(ps_snapshot)
}

# Emit orphaned MCP trees as: totalMB|pids to kill|age|name
find_orphans() {
  mem_snapshot | awk '
  { pid[NR]=$1; ppid[NR]=$2; et[NR]=$3; rss[NR]=$4; line[NR]=$0 }
  END {
    # orphan age: >24h ("-" in etime) OR HH:MM:SS with HH>=2 — so connectors
    # orphaned by an idle-session close get reaped within ~2h, not a day
    for (i=1; i<=NR; i++) {
      n = split(et[i], a, ":")
      old = (et[i] ~ /-/) || (n==3 && a[1]+0 >= 2)
      if (ppid[i]==1 && old && line[i] ~ /mcp/) root[pid[i]]=i
    }
    for (i=1; i<=NR; i++)
      if (ppid[i] in root) { j=root[ppid[i]]; kid_mb[j]+=rss[i]/1024; kids[j]=kids[j]" "pid[i] }
    for (p in root) {
      j=root[p]
      what=""; n=split(line[j], tok, " ")
      for (k=5; k<=n; k++) if (tok[k] ~ /mcp/) what=tok[k]
      m=split(what, seg, "/")
      printf "%.0f|%s%s|%s|%s\n", rss[j]/1024 + kid_mb[j], p, kids[j], et[j], seg[m]
    }
  }'
}

# Cheap ps-only orphan probe for the guard hot path: same predicate, RSS
# numbers. If it finds anything, the caller re-runs find_orphans for accurate
# footprint figures. Keeps the common "nothing to do" pass fast.
find_orphans_fast() { MEMSCOPE_NO_FOOTPRINT=1 find_orphans; }

# Absolute swap + disk facts. Percentage of a growing swapfile is a poor
# signal: it sat >=90% for five days straight while the machine was fine, then
# the machine wedged. What actually matters is HEADROOM (how much swap can
# still be allocated) and RATE (how fast it is being consumed). Swap can only
# grow into free disk, so disk space is the real ceiling.
swap_used_mb() { sysctl -n vm.swapusage | awk '{gsub(/M/,"",$6); print int($6)}'; }
swap_free_mb() { sysctl -n vm.swapusage | awk '{gsub(/M/,"",$9); print int($9)}'; }
disk_free_gb() { df -g / 2>/dev/null | awk 'NR==2{print $4}'; }

# Swap growth (MB) over roughly the last 10 minutes, from our own metrics.
swap_growth_mb() {
  local m="$LOG_DIR/metrics.jsonl" now
  [ -s "$m" ] || { echo 0; return; }
  now=$(swap_used_mb)
  tail -6 "$m" | head -1 | awk -v now="$now" '
    match($0, /"swap_used_mb":[0-9]+/) {
      then = substr($0, RSTART+16, RLENGTH-16)+0
      print int(now - then); found=1
    }
    END { if (!found) print 0 }'
}

swap_pct() {
  sysctl -n vm.swapusage | awk '{t=$3; u=$6; gsub(/M/,"",t); gsub(/M/,"",u); if (t>0) printf "%.0f", u*100/t; else print 0}'
}

pressure_level() {
  # 1=normal 2=warn 4=critical; fall back to swap heuristic if sysctl missing
  sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || {
    [ "$(swap_pct)" -ge 90 ] && echo 4 || echo 1
  }
}

# none | warn | critical — based on headroom and rate, not on a percentage
# that has been pinned for days.
pressure_tier() {
  local free growth disk
  free=$(swap_free_mb); growth=$(swap_growth_mb); disk=$(disk_free_gb)
  if [ "${free:-9999}" -lt 1024 ] || [ "${disk:-999}" -lt 8 ] \
     || { [ "${growth:-0}" -gt 3000 ] && [ "${free:-9999}" -lt 3072 ]; }; then
    echo critical
  elif [ "${free:-9999}" -lt 3072 ] || [ "${growth:-0}" -gt 2000 ] \
     || [ "${disk:-999}" -lt 20 ]; then
    echo warn
  else
    echo none
  fi
}

# Reclaim candidates, classified by what you would lose.
#
#   safe        — no user state at all: long-running dev servers (webpack/vite/
#                 next/nodemon) that only need restarting. Nothing unsaved.
#   recoverable — restores its own state on relaunch (browsers reopen tabs).
#   risky       — may hold unsaved work (Excel, Word, editors). NEVER offered.
#
# Only "safe" is ever actionable from the alert. Everything else is named as
# advice, so the decision stays with the human who knows what is unsaved.
safe_candidates() {   # "MB|pid|label"
  mem_snapshot | awk '
    # dev servers only: a "start"/"serve"/"dev" watcher, not a running build
    /react-scripts\/scripts\/start\.js|webpack(-dev)?-server|vite|next dev|nodemon/ &&
    !/react-scripts build|memscope/ {
      mins = 0
      n = split($3, t, ":")
      if ($3 ~ /-/)      mins = 1440              # days: definitely long-running
      else if (n == 3)   mins = t[1]*60 + t[2]
      else if (n == 2)   mins = t[1]
      if (mins < 30) next                          # spare anything just started
      name = "dev server"
      if (match($0, /worktrees\/[^\/]+\/[^\/]+/)) {
        seg = substr($0, RSTART+10, RLENGTH-10)
        sub(/^[^\/]*\//, "", seg); name = "dev server (" seg ")"
      }
      printf "%.0f|%s|%s, idle %dh\n", $4/1024, $1, name, mins/60
    }'
}

# Largest GUI app, named as advice only — never given a button.
biggest_app() {
  mem_snapshot | awk '
    match($0, /\/Applications\/[^\/]*\.app\//) {
      n = substr($0, RSTART+14, RLENGTH-19); mb[n] += $4/1024
    }
    END { best=""; b=0; for (a in mb) if (mb[a] > b) { b=mb[a]; best=a }
          if (best != "") printf "%s|%.1f", best, b/1024 }'
}

# Critical alert. Offers ONE action, and only when it is provably safe:
# stopping long-idle dev servers. Default button is always "Not now", so a
# reflexive Return never destroys anything. Runs detached — a guard pass is
# never blocked waiting for a human.
critical_dialog() { # $1 reason
  local cands total n app appname appgb msg pids
  cands=$(safe_candidates)
  app=$(biggest_app); appname=${app%%|*}; appgb=${app##*|}

  if [ -n "$cands" ]; then
    total=$(printf '%s\n' "$cands" | awk -F'|' '{s+=$1} END{printf "%.1f", s/1024}')
    n=$(printf '%s\n' "$cands" | grep -c .)
    pids=$(printf '%s\n' "$cands" | awk -F'|' '{printf "%s ", $2}')
    msg="$1

Safe to stop now — nothing unsaved:
$(printf '%s\n' "$cands" | awk -F'|' '{printf "  • %s  (%.1f GB)\n", $3, $1/1024}')
Frees about ${total} GB. They restart with one command.

Largest app is ${appname} (${appgb} GB) — your call, not mine."
    ( osascript >/dev/null 2>&1 <<OSA &
tell application "System Events"
  set r to button returned of (display alert "memscope — memory critical" ¬
    message "$msg" as critical ¬
    buttons {"Stop ${n} dev server(s)", "Not now"} default button "Not now" ¬
    giving up after 300)
  if r starts with "Stop" then do shell script "kill ${pids}"
end tell
OSA
    ) &
  else
    # Nothing safe to offer: inform only, no action button at all.
    msg="$1

Nothing can be freed safely — no idle dev servers to stop.
Largest app is ${appname} (${appgb} GB). Closing it would help, but only you
know what is unsaved in it."
    ( osascript >/dev/null 2>&1 <<OSA &
tell application "System Events"
  display alert "memscope — memory critical" message "$msg" as critical ¬
    buttons {"OK"} default button "OK" giving up after 300
end tell
OSA
    ) &
  fi
}

notify() { # $1 title, $2 body
  [ -n "${MEMSCOPE_NO_NOTIFY:-}" ] && return 0
  osascript -e "display notification \"$2\" with title \"$1\"" 2>/dev/null || true
}

# Idle-session auto-close: a session whose process accrues <10s CPU over
# MEMSCOPE_IDLE_HOURS (default 6, 0=off) is unread — TERM it. Transcripts are
# persisted on disk and sessions are resumable; only warm state is lost.
# State: $LOG_DIR/sessions.state lines "pid|starthash|idle_since|cpu_at_idle"
reap_idle_sessions() {
  DRY="$1"; TS="$2"
  IDLE_H="${MEMSCOPE_IDLE_HOURS:-6}"
  [ "$IDLE_H" = "0" ] && return 0
  IDLE_SECS="${MEMSCOPE_IDLE_SECONDS:-$((IDLE_H * 3600))}"   # seconds override for tests
  STATE="$LOG_DIR/sessions.state"; touch "$STATE"
  NOW=$(date +%s)
  NEWSTATE=""

  # never touch our own ancestor chain (manual runs from inside a session)
  ANCESTORS=" "; p=$$
  while [ "$p" -gt 1 ] 2>/dev/null; do
    ANCESTORS="$ANCESTORS$p "
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ') || break
    [ -z "$p" ] && break
  done

  for pid in $(pgrep -f "claude.app/Contents/MacOS/claude" 2>/dev/null); do
    case "$ANCESTORS" in *" $pid "*) continue ;; esac
    CPU_S=$(ps -o time= -p "$pid" 2>/dev/null | awk -F: '{ if (NF==3) print $1*3600+$2*60+$3; else if (NF==2) print $1*60+$2; else print 0 }' | cut -d. -f1)
    [ -z "$CPU_S" ] && continue
    SHASH=$(ps -o lstart= -p "$pid" 2>/dev/null | tr -d ' :')
    KEY="${pid}|${SHASH}"
    PREV=$(grep "^${KEY}|" "$STATE" 2>/dev/null | head -1)
    if [ -n "$PREV" ]; then
      IDLE_SINCE=$(echo "$PREV" | cut -d'|' -f3)
      CPU_AT=$(echo "$PREV" | cut -d'|' -f4)
      if [ $((CPU_S - CPU_AT)) -gt 10 ]; then
        IDLE_SINCE=$NOW; CPU_AT=$CPU_S            # activity → reset idle clock
      elif [ $((NOW - IDLE_SINCE)) -gt "$IDLE_SECS" ]; then
        IDLE_HRS_ACTUAL=$(( (NOW - IDLE_SINCE) / 3600 ))
        if [ "$DRY" = 1 ]; then
          echo "[$TS] DRY would close idle session pid=$pid (no CPU activity ${IDLE_HRS_ACTUAL}h)" | tee -a "$GUARD_LOG"
        else
          kill -TERM "$pid" 2>/dev/null
          echo "[$TS] closed idle session pid=$pid (no CPU activity ${IDLE_HRS_ACTUAL}h)" >> "$GUARD_LOG"
          notify "memscope guard" "Closed session idle ${IDLE_HRS_ACTUAL}h (pid $pid). Resumable from the app."
        fi
        continue                                   # killed → drop from state
      fi
      NEWSTATE="${NEWSTATE}${KEY}|${IDLE_SINCE}|${CPU_AT}\n"
    else
      NEWSTATE="${NEWSTATE}${KEY}|${NOW}|${CPU_S}\n"
    fi
  done
  printf '%b' "$NEWSTATE" > "$STATE"
}

# Biggest consumers by footprint — only computed when a notification will
# actually be sent (footprint costs ~1s; the silent path stays cheap).
topline_footprint() {
  mem_snapshot | awk '
    /Google Chrome/                 {c+=$4}
    /\/Applications\/Claude\.app\// {cl+=$4}
    $5 ~ /(^|\/)node$/              {n+=$4}
    END {printf "Chrome %.1fG, Claude %.1fG, node %.1fG", c/1048576, cl/1048576, n/1048576}'
}

run_guard() {
  DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
  mkdir -p "$LOG_DIR"
  TS=$(date "+%Y-%m-%d %H:%M:%S")
  LEVEL=$(pressure_level)
  SPCT=$(swap_pct)

  # 0. Idle sessions: TERM sessions unread for MEMSCOPE_IDLE_HOURS (default 6)
  reap_idle_sessions "$DRY" "$TS"

  # 1. Always reap garbage: orphaned MCP trees are dead sessions' leaks.
  # Probe cheaply; only pay for footprint measurement if there is something.
  ORPHANS=$(find_orphans_fast)
  [ -n "$ORPHANS" ] && ORPHANS=$(find_orphans)
  FREED_MB=0; TREES=0
  if [ -n "$ORPHANS" ]; then
    while IFS='|' read -r mb pids age name; do
      [ -z "$pids" ] && continue
      TREES=$((TREES+1)); FREED_MB=$((FREED_MB+mb))
      if [ "$DRY" = 1 ]; then
        echo "[$TS] DRY would kill: $name ($mb MB, up $age) pids:$pids" | tee -a "$GUARD_LOG"
      else
        # shellcheck disable=SC2086
        kill $pids 2>/dev/null
        echo "[$TS] reaped: $name ($mb MB, up $age) pids:$pids" >> "$GUARD_LOG"
      fi
    done <<< "$ORPHANS"
  fi

  # 2. Tiered alerting. The old rule (swap% >= 85 or kernel level >= 2) was
  # continuously true for five days — 263 alerts on the day the machine froze.
  # An alarm that never stops carries no information. Alert on deterioration
  # (headroom collapsing, swap growing fast), not on the steady state.
  TIER=$(pressure_tier)
  SWAP_FREE=$(swap_free_mb); GROWTH=$(swap_growth_mb); DISK_FREE=$(disk_free_gb)

  if [ "$TIER" != "none" ]; then
    # Cooldowns: warnings are quiet (60 min), critical is insistent (10 min).
    if [ "$TIER" = critical ]; then COOL=600; STAMP="$LOG_DIR/.last_critical"
    else                            COOL=3600; STAMP="$LOG_DIR/.last_alert"; fi
    ALERT_OK=1
    if [ -f "$STAMP" ]; then
      LAST=$(cat "$STAMP" 2>/dev/null || echo 0)
      [ $(( $(date +%s) - LAST )) -lt "$COOL" ] && ALERT_OK=0
    fi

    REASON="swap headroom ${SWAP_FREE}MB, disk ${DISK_FREE}GB free"
    [ "${GROWTH:-0}" -gt 500 ] && REASON="$REASON, +${GROWTH}MB swap in 10 min"

    if [ "$DRY" = 0 ] && [ "$ALERT_OK" = 1 ]; then
      if [ "$TIER" = critical ]; then
        critical_dialog "$REASON"
      else
        notify "memscope — memory pressure rising" "$REASON. Biggest: $(topline_footprint)."
      fi
      date +%s > "$STAMP"
    fi
    echo "[$TS] $TIER :: $REASON" >> "$GUARD_LOG"
  elif [ "$TREES" -gt 0 ] && [ "$DRY" = 0 ]; then
    notify "memscope guard" "Reaped ${TREES} dead MCP trees, freed ~${FREED_MB} MB"
  fi

  # Metrics: one JSONL line per real pass — the performance record
  if [ "$DRY" = 0 ]; then
    RES_GB=$(ps -Axo rss= | awk '{s+=$1} END{printf "%.1f", s/1048576}')
    printf '{"ts":"%s","level":%s,"swap_pct":%s,"resident_gb":%s,"trees":%s,"freed_mb":%s}\n' \
      "$TS" "$LEVEL" "$SPCT" "$RES_GB" "$TREES" "$FREED_MB" >> "$LOG_DIR/metrics.jsonl"
  fi

  [ "$DRY" = 1 ] && echo "[$TS] dry-run: level=$LEVEL swap=${SPCT}% trees=$TREES freeable=${FREED_MB}MB"
  return 0
}

run_status() {
  METRICS="$LOG_DIR/metrics.jsonl"
  if [ ! -s "$METRICS" ]; then
    echo "no guard passes recorded yet — run: $SELF guard   (or install-guard)"
    return 0
  fi
  echo "memscope guard — last 24h (samples every 2 min when installed)"
  tail -720 "$METRICS" | awk -F'[,:}]' '
  {
    for (i=1; i<=NF; i++) {
      if ($i ~ /"swap_pct"/)  sp[++n]=$(i+1)
      if ($i ~ /"trees"/)     trees+=$(i+1)
      if ($i ~ /"freed_mb"/)  freed+=$(i+1)
      if ($i ~ /"level"/ && $(i+1)>=2) alerts++
    }
  }
  END {
    if (n==0) { print "no samples"; exit }
    min=100; max=0
    for (i=1;i<=n;i++) { if (sp[i]<min) min=sp[i]; if (sp[i]>max) max=sp[i] }
    printf "passes: %d   orphan trees reaped: %d   freed: %d MB   pressure alerts: %d\n", n, trees, freed, alerts+0
    printf "swap now %s%%   min %d%%   max %d%%\n", sp[n], min, max
    # sparkline of the last 60 samples (~2h)
    s=""; start=(n>60)?n-59:1
    split("▁ ▂ ▃ ▄ ▅ ▆ ▇ █", blk, " ")   # space-split keeps multibyte chars whole in BSD awk
    for (i=start; i<=n; i++) { b=int(sp[i]/12.6)+1; if (b>8) b=8; s=s blk[b] }
    printf "swap trend: %s\n", s
  }'
  echo
  echo "recent guard actions:"
  tail -5 "$GUARD_LOG" 2>/dev/null || echo "  (none)"
}

run_summary() {
  DAY="${1:-$(date +%Y-%m-%d)}"
  METRICS="$LOG_DIR/metrics.jsonl"
  echo "memscope — $DAY"
  if [ ! -s "$METRICS" ] || ! grep -q "\"ts\":\"$DAY" "$METRICS" 2>/dev/null; then
    echo "no guard passes recorded on $DAY"
    return 0
  fi
  # Reap stats come from guard.log (authoritative for actions, and predates
  # the metrics file); passes/swap/alerts come from metrics.jsonl.
  REAPED=$(grep -c "^\[$DAY.*] reaped:" "$GUARD_LOG" 2>/dev/null | head -1); REAPED=${REAPED:-0}
  FREED=$(grep "^\[$DAY.*] reaped:" "$GUARD_LOG" 2>/dev/null | grep -oE '\([0-9]+ MB' | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}')
  grep "\"ts\":\"$DAY" "$METRICS" | awk -F'[,:}]' -v reaped="$REAPED" -v freed="$FREED" '
  {
    for (i=1; i<=NF; i++) {
      if ($i ~ /"swap_pct"/)  { v=$(i+1); n++; if (min==""||v<min) min=v; if (v>max) max=v; last=v; if (first=="") first=v }
      if ($i ~ /"level"/ && $(i+1)>=2) alerts++
    }
  }
  END {
    printf "ran %d times", n
    if (reaped>0) printf " · reaped %d orphaned MCP trees · reclaimed ~%d MB RSS", reaped, freed
    else printf " · no orphans found (machine stayed clean)"
    printf "\n"
    printf "swap: started %s%% · ended %s%% · range %s–%s%%", first, last, min, max
    if (alerts>0) printf " · %d pressure alerts logged", alerts
    printf "\n"
  }'
  CLOSED=$(grep -c "^\[$DAY.*closed idle session" "$GUARD_LOG" 2>/dev/null | head -1)
  [ "${CLOSED:-0}" -gt 0 ] 2>/dev/null && echo "closed $CLOSED idle sessions (6h+ unread, resumable)"
  ACTIONS=$(grep "^\[$DAY" "$GUARD_LOG" 2>/dev/null | grep -vc "DRY")
  echo
  echo "actions logged: ${ACTIONS:-0}   (details: $GUARD_LOG)"
}

# Named per-app census: "MB|procs|App Name", biggest first.
app_census() {
  mem_snapshot | awk '
  {
    rss=$4; name=""
    if ($0 ~ /claude-code\//)                          name="Claude Code sessions"
    else if (match($0, /\/Applications\/[^\/]*\.app\//))
      name = substr($0, RSTART+14, RLENGTH-19)
    else if ($5 ~ /(^|\/)(node|bun|deno|tsx)$/)        name="agent tooling (node/MCP)"
    else if ($5 ~ /(^|\/)java$/)                       name="Java"
    else if ($5 ~ /(postgres|mysqld|mongod)$/)         name="local databases"
    else next
    mb[name]+=rss/1024; cnt[name]++
  }
  END { for (a in mb) printf "%.0f|%d|%s\n", mb[a], cnt[a], a }' | sort -rn -t'|'
}

# The story: what is running, what is dead weight, what a reap gives back.
run_receipt() {
  case " $* " in *" --reap "*) REAP=1 ;; *) REAP=0 ;; esac
  SWAP_BEFORE_MB=$(sysctl -n vm.swapusage | awk '{gsub(/M/,"",$6); print int($6)}')
  RSS_BEFORE_MB=$(mem_snapshot | awk '{s+=$4} END{printf "%.0f", s/1024}')

  CENSUS=$(app_census)
  NAPPS=$(printf '%s\n' "$CENSUS" | grep -c . )
  NPROC=$(printf '%s\n' "$CENSUS" | awk -F'|' '{s+=$2} END{print s+0}')

  printf '%s\n' "${B}${CYN}WHAT IS RUNNING${R}"
  hr
  printf "%d apps · %d processes · %.1f GB footprint · %.1f GB swapped\n" \
    "$NAPPS" "$NPROC" "$(echo "$RSS_BEFORE_MB" | awk '{print $1/1024}')" \
    "$(echo "$SWAP_BEFORE_MB" | awk '{print $1/1024}')"
  printf "%s\n" "${DIM}footprint = resident + compressed + swapped (what Activity Monitor shows).${R}"
  printf "%s\n\n" "${DIM}Processes share memory, so per-app figures sum above physical RAM.${R}"
  printf '%s\n' "$CENSUS" | head -10 | awk -F'|' \
    '{printf "  %-28s %7.2f GB  %3d proc\n", $3, $1/1024, $2}'

  ORPHANS=$(find_orphans)
  NTREES=0; DEADMB=0
  if [ -n "$ORPHANS" ]; then
    NTREES=$(printf '%s\n' "$ORPHANS" | grep -c .)
    DEADMB=$(printf '%s\n' "$ORPHANS" | awk -F'|' '{s+=$1} END{printf "%.0f", s}')
  fi

  printf '\n%s\n' "${B}${CYN}WHAT IS ALREADY DEAD${R}"
  hr
  if [ "$NTREES" = 0 ]; then
    printf "%s\n" "${GRN}No zombie process trees. Every process above has a living parent.${R}"
    TOTAL_REAPS=$(grep -c "] reaped:" "$GUARD_LOG" 2>/dev/null || echo 0)
    [ "${TOTAL_REAPS:-0}" -gt 0 ] && \
      printf "%s\n" "${DIM}(guard has reaped ${TOTAL_REAPS} trees to date — this machine is being kept clean)${R}"
    return 0
  fi

  printf '%s\n' "$ORPHANS" | sort -rn -t'|' | head -8 | awk -F'|' \
    '{printf "  %-28s %7.0f MB   dead for %s\n", $4, $1, $3}'
  printf "  %s\n" "${YEL}${NTREES} zombie trees · ~${DEADMB} MB of RAM held by work that finished${R}"

  if [ "$REAP" = 0 ]; then
    printf '\n%s\n' "${DIM}Run: memscope.sh receipt --reap   to kill them and print the after-picture.${R}"
    return 0
  fi

  printf '\n%s\n' "${B}${CYN}REAPING${R}"
  hr
  printf '%s\n' "$ORPHANS" | while IFS='|' read -r mb pids age name; do
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] reaped: $name ($mb MB, up $age) pids:$pids" >> "$GUARD_LOG"
  done

  SWAP_AFTER_MB=$(sysctl -n vm.swapusage | awk '{gsub(/M/,"",$6); print int($6)}')
  RSS_AFTER_MB=$(mem_snapshot | awk '{s+=$4} END{printf "%.0f", s/1024}')
  printf "killed %d zombie trees\n\n" "$NTREES"
  printf '%s\n' "${B}${GRN}REGAINED${R}"
  hr
  awk -v rb="$RSS_BEFORE_MB" -v ra="$RSS_AFTER_MB" -v sb="$SWAP_BEFORE_MB" -v sa="$SWAP_AFTER_MB" 'BEGIN{
    printf "  resident  %6.2f GB → %6.2f GB   (%+.0f MB)\n", rb/1024, ra/1024, ra-rb
    printf "  swap      %6.2f GB → %6.2f GB   (%+.0f MB)\n", sb/1024, sa/1024, sa-sb
    printf "  total reclaimed: %.0f MB\n", (rb-ra)+(sb-sa)
  }'
  printf "%s\n" "${DIM}macOS keeps draining swap for a few minutes — re-run to see the settled number.${R}"
}

run_menubar() {
  # SwiftBar/xbar plugin format. Install SwiftBar, then symlink:
  #   ln -s <this script's menubar wrapper> ~/SwiftBar/memscope.2m.sh
  SPCT=$(swap_pct)
  ICON="🧠"
  [ "$SPCT" -ge 70 ] && ICON="⚠️"
  [ "$SPCT" -ge 90 ] && ICON="🔴"
  echo "$ICON ${SPCT}%"
  echo "---"
  ps -Axo rss= | awk '{s+=$1} END{printf "Resident: %.1f GB\n", s/1048576}'
  sysctl -n vm.swapusage | awk '{printf "Swap: %s used of %s\n", $6, $3}'
  if [ -s "$LOG_DIR/metrics.jsonl" ]; then
    TODAY=$(date "+%Y-%m-%d")
    grep "\"ts\":\"$TODAY" "$LOG_DIR/metrics.jsonl" | awk -F'[,:}]' '
    { for (i=1;i<=NF;i++) { if ($i ~ /"trees"/) t+=$(i+1); if ($i ~ /"freed_mb"/) f+=$(i+1) } }
    END { printf "Reaped today: %d trees, %d MB\n", t+0, f+0 }'
  fi
  echo "Reap orphans now | bash=$SELF param1=guard terminal=false refresh=true"
  echo "Full census | bash=$SELF terminal=true"
}

case "$MODE" in
  guard) run_guard "${1:-}"; exit 0 ;;
  status) run_status; exit 0 ;;
  summary) run_summary "${1:-}"; exit 0 ;;
  receipt) run_receipt "$@"; exit 0 ;;
  menubar) run_menubar; exit 0 ;;
  install-guard)
    mkdir -p "$LOG_DIR" "$HOME/Library/LaunchAgents"
    cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$SELF</string><string>guard</string>
  </array>
  <key>StartInterval</key><integer>120</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$LOG_DIR/guard.out</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/guard.err</string>
</dict></plist>
PLIST_EOF
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load -w "$PLIST"
    echo "installed: guard runs every 2 min (log: $GUARD_LOG)"
    echo "uninstall: $SELF uninstall-guard"
    exit 0 ;;
  uninstall-guard)
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "guard uninstalled"
    exit 0 ;;
esac

TOP=8
COLOR=1
while [ $# -gt 0 ]; do
  case "$1" in
    --top) TOP="${2:-8}"; shift 2 ;;
    --no-color) COLOR=0; shift ;;
    *) echo "usage: memscope.sh [report|receipt|guard|status|summary|menubar|install-guard|uninstall-guard] [--top N] [--no-color]" >&2; exit 1 ;;
  esac
done
[ -t 1 ] || COLOR=0

section() { printf '\n%s\n' "${B}${CYN}$1${R}"; hr; }

# Snapshot process table once; reuse everywhere.
# Fields: pid ppid etime rss(all in KB) args...
PS_SNAPSHOT="$(mem_snapshot)"

# ---------------------------------------------------------------- 1. pressure
section "SYSTEM PRESSURE"

TOTAL_RAM_GB=$(sysctl -n hw.memsize | awk '{printf "%.0f", $1/1073741824}')
SWAP_LINE=$(sysctl -n vm.swapusage)
SWAP_TOTAL=$(echo "$SWAP_LINE" | awk '{print $3}' | tr -d 'M')
SWAP_USED=$(echo "$SWAP_LINE" | awk '{print $6}' | tr -d 'M')
SWAP_PCT=$(awk -v u="$SWAP_USED" -v t="$SWAP_TOTAL" 'BEGIN{ if (t>0) printf "%.0f", u*100/t; else print 0 }')
NOW_EPOCH=$(date +%s)
UPTIME_DAYS=$(sysctl -n kern.boottime | awk -F'sec = ' '{print $2}' | awk -F',' -v now="$NOW_EPOCH" '{printf "%.1f", (now-$1)/86400}')
FREE_PCT=$(memory_pressure 2>/dev/null | awk -F': ' '/free percentage/{print $2}' | tr -d '%' | tr -d ' ')

PAGE_SIZE=$(sysctl -n hw.pagesize)
COMPRESSED_GB=$(memory_pressure 2>/dev/null | awk -F': ' -v ps="$PAGE_SIZE" '/Pages compressed/{printf "%.1f", $2*ps/1073741824}')
DECOMP_GB=$(memory_pressure 2>/dev/null | awk -F': ' -v ps="$PAGE_SIZE" '/Pages decompressed/{printf "%.1f", $2*ps/1073741824}')
PAGEINS_GB=$(memory_pressure 2>/dev/null | awk -F': ' -v ps="$PAGE_SIZE" '/Pageins/{printf "%.1f", $2*ps/1073741824}')

RSS_TOTAL_GB=$(echo "$PS_SNAPSHOT" | awk '{s+=$4} END{printf "%.1f", s/1048576}')
DEMAND_GB=$(awk -v r="$RSS_TOTAL_GB" -v s="$SWAP_USED" 'BEGIN{printf "%.1f", r + s/1024}')

printf "RAM %s GB   resident %s GB   swap %s/%s MB (%s%%)   uptime %s d\n" \
  "$TOTAL_RAM_GB" "$RSS_TOTAL_GB" "$SWAP_USED" "$SWAP_TOTAL" "$SWAP_PCT" "$UPTIME_DAYS"
printf "Since boot: compressed %s GB, decompressed %s GB, paged in %s GB\n" \
  "$COMPRESSED_GB" "$DECOMP_GB" "$PAGEINS_GB"

VERDICT_DEMAND=$(awk -v d="$DEMAND_GB" -v t="$TOTAL_RAM_GB" 'BEGIN{printf "%.0f", d*100/t}')
if [ "$SWAP_PCT" -gt 70 ]; then
  printf "%s\n" "${RED}${B}▲ THRASHING${R}${RED} — demand ≈ ${DEMAND_GB} GB on ${TOTAL_RAM_GB} GB (${VERDICT_DEMAND}%). Hygiene helps; only more RAM or offloading cures.${R}"
elif [ "$SWAP_PCT" -gt 30 ]; then
  printf "%s\n" "${YEL}● Under pressure — demand ≈ ${DEMAND_GB} GB on ${TOTAL_RAM_GB} GB (${VERDICT_DEMAND}%).${R}"
else
  printf "%s\n" "${GRN}✓ Healthy — demand ≈ ${DEMAND_GB} GB on ${TOTAL_RAM_GB} GB (${VERDICT_DEMAND}%).${R}"
fi

# ---------------------------------------------------- 2. census by app family
section "CENSUS BY FAMILY (resident only — swapped-out pages not attributed)"

echo "$PS_SNAPSHOT" | awk '
# exe = $5 (first token of args); classify on the binary, not args mentions —
# MCP servers named "postgres"/"mongodb" in args must still bucket as node
function bucket(exe, args) {
  if (args ~ /Google Chrome/)                              return "Chrome"
  if (exe ~ /(^|\/)(node|tsx|bun|deno)$/)                  return "node/agents"
  if (match(args, /\/[^\/]*\.app\//)) {
    app = substr(args, 1, RSTART+RLENGTH-2)
    n = split(app, parts, "/")
    return tolower(parts[n])              # e.g. "claude.app", "slack.app"
  }
  if (exe ~ /(^|\/)java$/ || args ~ /dbeaver/)             return "java"
  if (exe ~ /(^|\/)[Pp]ython[0-9.]*$/)                     return "python"
  if (exe ~ /(postgres|mysqld|mongod|redis-server)$/)      return "databases"
  if (exe ~ /^\/(System\/|usr\/libexec|usr\/sbin|sbin\/)/) return "macOS system"
  return "other"
}
{
  b=bucket($5, $0); mb[b]+=$4/1024; cnt[b]++
}
END {
  for (x in mb) printf "%9.2f GB  %4d proc  %s\n", mb[x]/1024, cnt[x], x
}' | sort -rn | head -15

# --------------------------------------------------------- 3. chromium detail
section "CHROME — top renderers (long-lived SPA tabs leak; close & reopen)"

echo "$PS_SNAPSHOT" | awk -v top="$TOP" '
/Google Chrome Helper \(Renderer\)/ {
  rss=$4/1024; et=$3
  printf "%7.0f MB  up %-11s\n", rss, et
}' | sort -rn | head "-$TOP"
RENDERERS=$(echo "$PS_SNAPSHOT" | grep -c "Google Chrome Helper (Renderer)" || true)
printf "%s\n" "${DIM}${RENDERERS} renderer processes ≈ open tabs + extensions. Memory Saver: chrome://settings/performance${R}"

# ---------------------------------------------------------- 4. electron fleet
section "ELECTRON FLEET (each app ships its own private Chromium)"

echo "$PS_SNAPSHOT" | awk '
match($0, /\/Applications\/[^\/]*\.app\//) {
  app = substr($0, RSTART, RLENGTH-1)
  sub(/\/$/, "", app)
  mb[app] += $4/1024; cnt[app]++
}
END { for (a in mb) printf "%9.0f MB  %3d proc  %s\n", mb[a], cnt[a], a }
' | sort -rn | while IFS= read -r line; do
  APP_PATH=$(echo "$line" | sed 's/.*\/Applications/\/Applications/')
  if [ -d "$APP_PATH/Contents/Frameworks/Electron Framework.framework" ]; then
    printf '%s  %s\n' "$line" "${YEL}[Electron]${R}"
  else
    printf '%s\n' "$line"
  fi
done | head -10

# ------------------------------------------------- 5. node / agent-era sprawl
section "NODE / AGENT SPRAWL (MCP servers, dev servers, watchers)"

NODE_TOTAL=$(echo "$PS_SNAPSHOT" | awk '$5 ~ /(^|\/)(node|tsx|bun|deno)$/ {s+=$4; n++} END{printf "%.2f GB across %d processes", s/1048576, n+0}')
printf "Total: %s\n\n" "$NODE_TOTAL"

printf "%s\n" "${B}Top consumers:${R}"
echo "$PS_SNAPSHOT" | awk -v top="$TOP" '
$5 ~ /(^|\/)(node|tsx|bun|deno)$/ {
  rss=$4/1024; pid=$1; et=$3
  # find the script/server being run: last plausible path or mcp hint
  what=""
  for (i=6; i<=NF; i++) {
    if ($i ~ /mcp|server|dist\/|\.js$|\.ts$|\.mjs$/) { what=$i }
  }
  if (what=="") what=$6
  n = split(what, seg, "/")
  short = (n>2) ? seg[n-2]"/"seg[n-1]"/"seg[n] : what
  printf "%7.0f MB  pid %-7s up %-11s %s\n", rss, pid, et, short
}' | sort -rn | head "-$TOP"

# Duplicate connectors: several sessions each spawn the same MCP server
printf "\n%s\n" "${B}Duplicate MCP/connector processes (one per open session):${R}"
DUPES=$(echo "$PS_SNAPSHOT" | awk '
$5 ~ /(^|\/)(node|tsx|bun|deno)$/ {
  what=""
  for (i=6; i<=NF; i++) if ($i ~ /mcp|server|dist\/|\.js$|\.ts$|\.mjs$/) what=$i
  if (what=="") next
  n = split(what, seg, "/"); short = seg[n]
  if (short !~ /mcp/) next
  mb[short] += $4/1024; cnt[short]++
}
END { for (s in mb) if (cnt[s] > 1) printf "%7.0f MB  ×%d  %s\n", mb[s], cnt[s], s }' | sort -rn)
if [ -n "$DUPES" ]; then
  printf '%s\n' "$DUPES"
  printf "%s\n" "${DIM}Each open Claude/agent session spawns its own copy of every connector. Close idle sessions to reap them.${R}"
else
  printf "%s\n" "${GRN}none — one of each${R}"
fi

# Orphaned MCP trees: session died, launchd (ppid 1) adopted the connector
# wrapper; the wrapper plus its children idle forever. Root test: ppid=1,
# alive >24h ("-" in etime), args mention mcp. Children: ppid = a root pid.
printf "\n%s\n" "${B}Orphaned MCP trees (session is gone; connectors leaked) — verify, then kill:${R}"
ZOMBIES=$(echo "$PS_SNAPSHOT" | awk '
{ pid[NR]=$1; ppid[NR]=$2; et[NR]=$3; rss[NR]=$4; line[NR]=$0 }
END {
  for (i=1; i<=NR; i++)
    if (ppid[i]==1 && et[i] ~ /-/ && line[i] ~ /mcp/) { root[pid[i]]=i }
  for (i=1; i<=NR; i++)
    if (ppid[i] in root) { j=root[ppid[i]]; kid_mb[j]+=rss[i]/1024; kids[j]=kids[j]" "pid[i] }
  for (p in root) {
    j=root[p]
    what=""
    n=split(line[j], tok, " ")
    for (k=5; k<=n; k++) if (tok[k] ~ /mcp/) what=tok[k]
    m=split(what, seg, "/"); short=seg[m]
    total = rss[j]/1024 + kid_mb[j]
    printf "%7.0f MB  kill %s%s  # up %-11s %s\n", total, p, kids[j], et[j], short
  }
}' | sort -rn)
if [ -n "$ZOMBIES" ]; then
  printf '%s\n' "$ZOMBIES" | head -15
  N_TREES=$(printf '%s\n' "$ZOMBIES" | wc -l | tr -d ' ')
  ZOMBIE_MB=$(printf '%s\n' "$ZOMBIES" | awk '{s+=$1} END{printf "%.0f", s}')
  printf "%s\n" "${YEL}${N_TREES} orphaned trees, ~${ZOMBIE_MB} MB reclaimable. Kill roots+children together (listed per line).${R}"
else
  printf "%s\n" "${GRN}none found${R}"
fi

# ------------------------------------------------------------------ 6. verdict
section "VERDICT"

echo "$PS_SNAPSHOT" | awk -v ram="$TOTAL_RAM_GB" -v swap_used="$SWAP_USED" '
{
  rss=$4
  if ($0 ~ /Google Chrome Helper \(Renderer\)/) chrome_r += rss
  if ($0 ~ /\/Applications\/Claude\.app\//)     claude   += rss
  total += rss
}
END {
  printf "Resident %.1f GB + swap %.1f GB = ~%.1f GB demand on %d GB machine\n",
    total/1048576, swap_used/1024, total/1048576 + swap_used/1024, ram
  hygiene = (chrome_r*0.4 + claude) / 1048576
  printf "Quick hygiene (tab cull + redundant Electron): ~%.1f GB back\n", hygiene
  gap = total/1048576 + swap_used/1024 - ram
  if (gap > 1)
    printf "Structural gap: ~%.1f GB — no amount of cleanup closes this.\n", gap
}'
