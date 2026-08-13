#!/bin/bash
# memscope test suite — proves the two kill paths and the three spare paths.
# Run: ./test/run_tests.sh   (exit 0 = all green; no root, no side effects)

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
MEMSCOPE="$HERE/../memscope.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; [ -n "${FAKE_PID:-}" ] && kill "$FAKE_PID" 2>/dev/null' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi }

echo "── unit: orphan detection against a canned process table"
FIXTURE="$TMP/ps.fixture"
cat > "$FIXTURE" <<'EOF'
  101     1 03:12:34  2048 /bin/sh -c npm exec mcp-mongo-server mongodb+srv://x
  102   101 03:12:30 20480 node /x/node_modules/.bin/mcp-mongo-server
  201 55555 01-02:00:00 20480 node /x/node_modules/.bin/mcp-mysql
  301     1 01:30:00  8192 npm exec mongodb-mcp-server@<3
  401     1 05:00:00  1024 /bin/bash /Users/admin/development/memscope/memscope.sh guard
  501     1 26:10:00  4096 node /x/node_modules/.bin/playwright-mcp
EOF
# Extract just ps_snapshot() and find_orphans() from the script and run them
# against the fixture — pure unit test of the detection logic.
OUT=$(MEMSCOPE_PS_FIXTURE="$FIXTURE" bash -c '
  eval "$(sed -n "/^ps_snapshot()/,/^}/p; /^find_orphans()/,/^}/p" "'"$MEMSCOPE"'")"
  find_orphans
')
check "orphan >2h detected (root 101 + child 102)"      'echo "$OUT" | grep -q "|101 102|"'
check "26h orphan detected (pid 501)"                    'echo "$OUT" | grep -q "|501|"'
check "live-parented connector spared (pid 201)"         '! echo "$OUT" | grep -q "201"'
check "young orphan <2h spared (pid 301)"                '! echo "$OUT" | grep -q "301"'
check "memscope guard itself never matches (pid 401)"    '! echo "$OUT" | grep -q "401"'

echo "── integration: idle session really gets SIGTERM"
# Fake session: a script whose PATH matches the real pgrep pattern.
# (Cannot copy /bin/sleep — macOS SIGKILLs displaced platform binaries.)
FAKEDIR="$TMP/claude-code/9.9.9/claude.app/Contents/MacOS"
mkdir -p "$FAKEDIR"
printf '#!/bin/bash\nwhile true; do sleep 1; done\n' > "$FAKEDIR/claude"
chmod +x "$FAKEDIR/claude"
"$FAKEDIR/claude" &
FAKE_PID=$!
sleep 1
# Seed guard state: this pid has been idle since 2 minutes ago, cpu 0
SHASH=$(ps -o lstart= -p "$FAKE_PID" | tr -d ' :')
mkdir -p "$TMP/logdir"
printf '%s|%s|%s|0\n' "$FAKE_PID" "$SHASH" "$(( $(date +%s) - 120 ))" > "$TMP/logdir/sessions.state"
# Threshold 60s < 120s idle → must TERM. Notifications off, isolated logs.
MEMSCOPE_LOG_DIR="$TMP/logdir" MEMSCOPE_IDLE_SECONDS=60 MEMSCOPE_NO_NOTIFY=1 \
  "$MEMSCOPE" guard >/dev/null 2>&1
sleep 1
check "idle fake session terminated"                     '! kill -0 "$FAKE_PID" 2>/dev/null'
check "close was logged"                                 'grep -q "closed idle session pid=$FAKE_PID" "$TMP/logdir/guard.log"'

echo "── integration: fresh session is NOT killed (idle clock just started)"
"$FAKEDIR/claude" &
FAKE_PID=$!
sleep 1
rm -f "$TMP/logdir/sessions.state"
MEMSCOPE_LOG_DIR="$TMP/logdir" MEMSCOPE_IDLE_SECONDS=60 MEMSCOPE_NO_NOTIFY=1 \
  "$MEMSCOPE" guard >/dev/null 2>&1
check "first-seen session spared, only tracked"          'kill -0 "$FAKE_PID" 2>/dev/null'
check "session recorded in state"                        'grep -q "^$FAKE_PID|" "$TMP/logdir/sessions.state"'
kill "$FAKE_PID" 2>/dev/null; FAKE_PID=""

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" = 0 ]
