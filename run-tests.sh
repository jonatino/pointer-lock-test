#!/usr/bin/env bash
# Tests cosmic-comp's pointer-lock activation for Xwayland games.
#
# Launches the cosmic-comp build from ../cosmic-comp nested (winit backend,
# appears as a window in your session) with WAYLAND_DEBUG=1, runs X11
# scenarios against its Xwayland, and reads the verdict off the wire:
#
#   client -> server  zwp_pointer_constraints_v1.lock_pointer(new_id, ...)
#   server -> client  zwp_locked_pointer_v1@new_id.locked()     <- activated
#                     zwp_locked_pointer_v1@new_id.unlocked()   <- deactivated
#
# A game gets relative motion only after `locked`. "lock requested but never
# locked" is exactly the Helldivers-2-style failure.
#
# Usage: ./run-tests.sh
# For an unpatched control: (cd ../cosmic-comp && git stash) and rerun.
set -uo pipefail

COMP_DIR=${COMP_DIR:-"$(cd "$(dirname "$0")/../cosmic-comp" && pwd)"}
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG=/tmp/cosmic-nested-test.log
BIN="$TEST_DIR/target/debug/pointer-lock-test"

echo "building cosmic-comp..."
cargo build --manifest-path "$COMP_DIR/Cargo.toml" -q || exit 2
echo "building pointer-lock-test..."
cargo build --manifest-path "$TEST_DIR/Cargo.toml" -q || exit 2

# Displays already responsive before launch (stale sockets don't respond).
declare -A before
for d in $(seq 2 9); do
    if DISPLAY=":$d" "$BIN" probe 2>/dev/null; then before[$d]=1; fi
done

# Throwaway config for the nested instance (never touches your real one).
# cursor_follows_focus warps the pointer to the focused window's centre, which
# is the only way to place the nested pointer deterministically: without
# physical mouse input over the nested window the pointer sits wherever it
# started, and Xwayland only engages warp emulation for a surface that has
# pointer focus.
CONF=$(mktemp -d)
trap 'rm -rf "$CONF"' EXIT
mkdir -p "$CONF/cosmic/com.system76.CosmicComp/v1"
printf 'true' >"$CONF/cosmic/com.system76.CosmicComp/v1/cursor_follows_focus"

XDG_CONFIG_HOME="$CONF" WAYLAND_DEBUG=1 COSMIC_BACKEND=winit \
    "$COMP_DIR/target/debug/cosmic-comp" &>"$LOG" &
COMP_PID=$!
trap 'kill $COMP_PID 2>/dev/null; rm -rf "$CONF"' EXIT

nested=""
for _ in $(seq 1 100); do
    sleep 0.2
    kill -0 "$COMP_PID" 2>/dev/null || { echo "nested cosmic-comp died:"; tail -5 "$LOG"; exit 2; }
    for d in $(seq 2 9); do
        if [ -z "${before[$d]:-}" ] && DISPLAY=":$d" "$BIN" probe 2>/dev/null; then
            nested=$d; break 2
        fi
    done
done
[ -z "$nested" ] && { echo "nested Xwayland never appeared:"; tail -5 "$LOG"; exit 2; }
export DISPLAY=":$nested"
unset WAYLAND_DISPLAY
echo "nested cosmic-comp pid $COMP_PID, Xwayland on $DISPLAY"
sleep 2

# Verdict for the log written since byte offset $1, labelled $2.
verdict() {
    local off=$1 label=$2
    local seg ids id locked unlocked last
    seg=$(tail -c "+$off" "$LOG")

    ids=$(grep -oE 'zwp_pointer_constraints_v1@[0-9]+\.lock_pointer, \([0-9]+' <<<"$seg" \
          | grep -oE '[0-9]+$' | sort -u)
    if [ -z "$ids" ]; then
        echo "[$label] INCONCLUSIVE: Xwayland never requested a pointer lock"
        echo "         (warp emulation did not engage — scenario precondition failed)"
        return 2
    fi

    for id in $ids; do
        locked=$(grep -cE "^\[[^]]*\]\[rs\] -> zwp_locked_pointer_v1@$id\.locked" <<<"$seg")
        unlocked=$(grep -cE "^\[[^]]*\]\[rs\] -> zwp_locked_pointer_v1@$id\.unlocked" <<<"$seg")
        last=$(grep -oE "zwp_locked_pointer_v1@$id\.(locked|unlocked)" <<<"$seg" | tail -1)
        if [ "$locked" -eq 0 ]; then
            echo "[$label] FAIL: lock #$id requested but compositor never activated it"
            echo "         (no .locked event -> game receives no relative motion)"
            return 1
        fi
        if [ "$last" = "zwp_locked_pointer_v1@$id.unlocked" ]; then
            echo "[$label] FAIL: lock #$id was activated then deactivated and not restored"
            echo "         ($locked locked / $unlocked unlocked events, ended unlocked)"
            return 1
        fi
    done
    echo "[$label] PASS: pointer lock(s) [$(tr '\n' ' ' <<<"$ids")] activated and still held"
    return 0
}

run_case() {  # label, scenario args...
    local label=$1; shift
    local off
    off=$(( $(wc -c <"$LOG") + 1 ))
    "$BIN" "$@" >/dev/null || { echo "[$label] SETUP ERROR (client exited $?)"; return 2; }
    sleep 0.5
    verdict "$off" "$label"
}

fail=0

echo
echo "== TEST 1: baseline — managed fullscreen X11 window grabs pointer =="
run_case baseline baseline || fail=1

echo
echo "== TEST 2: override-redirect grab, X11 keyboard focus elsewhere (Helldivers repro) =="
run_case or-grab or-grab || fail=1

echo
echo "== TEST 3: lock survives fullscreen off/on transitions =="
run_case fs-toggle fs-toggle || fail=1

echo
if [ "$fail" -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "SOME TESTS FAILED"; fi
exit $fail
