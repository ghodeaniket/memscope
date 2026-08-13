#!/bin/bash
# memscope — memory census for the agent-era Mac
# What's actually eating your RAM: Chromium fleet, Electron apps, node/MCP
# sprawl, zombie dev processes. Read-only: prints kill commands, never runs them.
#
# Usage: memscope.sh [--top N] [--no-color]

set -u

TOP=8
COLOR=1
while [ $# -gt 0 ]; do
  case "$1" in
    --top) TOP="${2:-8}"; shift 2 ;;
    --no-color) COLOR=0; shift ;;
    *) echo "usage: memscope.sh [--top N] [--no-color]" >&2; exit 1 ;;
  esac
done
[ -t 1 ] || COLOR=0

if [ "$COLOR" = 1 ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; CYN=$'\033[36m'; R=$'\033[0m'
else
  B=""; DIM=""; RED=""; YEL=""; GRN=""; CYN=""; R=""
fi

hr() { printf '%s\n' "${DIM}────────────────────────────────────────────────────────────${R}"; }
section() { printf '\n%s\n' "${B}${CYN}$1${R}"; hr; }

# Snapshot process table once; reuse everywhere.
# Fields: pid ppid etime rss(all in KB) args...
PS_SNAPSHOT="$(ps -Axo pid=,ppid=,etime=,rss=,args=)"

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
