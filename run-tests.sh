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
LOG=${LOG:-/tmp/cosmic-nested-test.log}
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
printf '%s' "${CURSOR_FOLLOWS_FOCUS:-true}" \
    >"$CONF/cosmic/com.system76.CosmicComp/v1/cursor_follows_focus"

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

last_lock_id() {
    local off=$1
    tail -c "+$off" "$LOG" \
        | grep -oE 'zwp_pointer_constraints_v1@[0-9]+\.lock_pointer, \([0-9]+' \
        | grep -oE '[0-9]+$' \
        | tail -1
}

last_lock_state() {
    local off=$1 id=$2
    tail -c "+$off" "$LOG" \
        | grep -oE "zwp_locked_pointer_v1@$id\.(locked|unlocked)" \
        | tail -1
}

run_focus_away_repro() {
    local off id state
    off=$(( $(wc -c <"$LOG") + 1 ))
    "$BIN" focus-away-grabbed >/dev/null || {
        echo "[focus-away-grabbed] SETUP ERROR (client exited $?)"
        return 2
    }
    sleep 0.5
    id=$(last_lock_id "$off")
    if [ -z "$id" ]; then
        echo "[focus-away-grabbed] INCONCLUSIVE: no pointer lock requested"
        return 2
    fi
    state=$(last_lock_state "$off" "$id")
    if [ "$state" = "zwp_locked_pointer_v1@$id.locked" ]; then
        echo "[focus-away-grabbed] REPRODUCED: lock #$id is still active after focus moved away"
        return 1
    fi
    echo "[focus-away-grabbed] NOT REPRODUCED: lock #$id ended unlocked after focus moved away"
    return 0
}

run_focus_cycle_repro() {
    local off ids first last state count
    off=$(( $(wc -c <"$LOG") + 1 ))
    "$BIN" focus-cycle >/dev/null || {
        echo "[focus-cycle] SETUP ERROR (client exited $?)"
        return 2
    }
    sleep 0.5
    ids=$(tail -c "+$off" "$LOG" \
        | grep -oE 'zwp_pointer_constraints_v1@[0-9]+\.lock_pointer, \([0-9]+' \
        | grep -oE '[0-9]+$')
    count=$(wc -w <<<"$ids")
    if [ -z "$ids" ]; then
        echo "[focus-cycle] INCONCLUSIVE: no pointer lock requested"
        return 2
    fi
    first=$(head -1 <<<"$ids")
    last=$(tail -1 <<<"$ids")
    state=$(last_lock_state "$off" "$last")
    if [ "$count" -lt 2 ]; then
        echo "[focus-cycle] REPRODUCED: only initial lock #$first was requested; no fresh lock after focus return"
        return 1
    fi
    if [ "$state" != "zwp_locked_pointer_v1@$last.locked" ]; then
        echo "[focus-cycle] REPRODUCED: return lock #$last did not end active (state: ${state:-none})"
        return 1
    fi
    echo "[focus-cycle] NOT REPRODUCED: return lock #$last was requested and activated"
    return 0
}

fail=0

if [ "${ONLY:-}" = "baseline" ]; then
    run_case baseline baseline
    exit $?
fi

if [ "${ONLY:-}" = "or-grab" ]; then
    run_case or-grab or-grab
    exit $?
fi

if [ "${ONLY:-}" = "fs-toggle" ]; then
    run_case fs-toggle fs-toggle
    exit $?
fi

if [ "${ONLY:-}" = "focus-away" ]; then
    run_focus_away_repro
    exit $?
fi

if [ "${ONLY:-}" = "focus-cycle" ]; then
    for attempt in $(seq 1 "${ATTEMPTS:-1}"); do
        echo "[focus-cycle] attempt $attempt"
        run_focus_cycle_repro || exit $?
    done
    exit 0
fi

if [[ "${ONLY:-}" == startup-* ]]; then
    run_case "$ONLY" "$ONLY"
    exit $?
fi

if [ "${ONLY:-}" = "poison-session" ]; then
    poisoned=0
    for attempt in $(seq 1 "${POISON_ATTEMPTS:-12}"); do
        echo "[poison-session] trigger attempt $attempt"
        if ! run_focus_cycle_repro; then
            poisoned=1
            echo "[poison-session] trigger reproduced; probing a fresh X11 game in the same compositor/Xwayland session"
            break
        fi
    done

    if [ "$poisoned" -eq 0 ]; then
        echo "[poison-session] INCONCLUSIVE: trigger did not reproduce"
        exit 2
    fi

    run_case baseline-after-poison baseline
    baseline_rc=$?
    run_case or-grab-after-poison or-grab
    or_rc=$?

    if [ "$baseline_rc" -ne 0 ] || [ "$or_rc" -ne 0 ]; then
        echo "[poison-session] REPRODUCED: a fresh client is broken after the trigger"
        exit 1
    fi

    echo "[poison-session] trigger was client-local; fresh clients still work"
    exit 0
fi

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
echo "== REPRO 4: focus leaves while game keeps pointer grab (KCD2 shape) =="
run_focus_away_repro || true

echo
echo "== REPRO 5: game releases grab on focus-out and reacquires on focus-in (Cyberpunk shape) =="
run_focus_cycle_repro || true

echo
if [ "$fail" -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "SOME TESTS FAILED"; fi
exit $fail
