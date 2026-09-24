#!/usr/bin/env bash
set -euo pipefail

COMP_DIR=${COMP_DIR:-/home/user/Code/cosmic-comp-v2-nested}
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
BIN="$TEST_DIR/target/debug/pointer-lock-test"
FOCUS_HELPER=/home/user/Code/wine-mouse-repro/focus-cosmic
LOG=${LOG:-/tmp/cosmic-hover-fresh-lock.log}
APP_LOG=${APP_LOG:-/tmp/cosmic-hover-fresh-lock-app.log}
EXPECT_ACTIVATED_UNFOCUSED=${EXPECT_ACTIVATED_UNFOCUSED:-0}

cargo build --manifest-path "$COMP_DIR/Cargo.toml" -q
cargo build --manifest-path "$TEST_DIR/Cargo.toml" -q
make -C /home/user/Code/wine-mouse-repro -s focus-cosmic

declare -A before
for d in $(seq 2 9); do
    if DISPLAY=":$d" "$BIN" probe 2>/dev/null; then before[$d]=1; fi
done

CONF=$(mktemp -d /tmp/cosmic-hover-fresh-conf.XXXXXX)
mkdir -p "$CONF/cosmic/com.system76.CosmicComp/v1"
printf '%s' false >"$CONF/cosmic/com.system76.CosmicComp/v1/cursor_follows_focus"
printf '%s' false >"$CONF/cosmic/com.system76.CosmicComp/v1/focus_follows_cursor"

DISPLAY=:1 XDG_CONFIG_HOME="$CONF" WAYLAND_DEBUG=1 COSMIC_BACKEND=x11 \
    env -u WAYLAND_DISPLAY "$COMP_DIR/target/debug/cosmic-comp" &>"$LOG" &
COMP_PID=$!
APP_PID=""
NATIVE_PID=""
cleanup() {
    [ -z "$NATIVE_PID" ] || kill "$NATIVE_PID" 2>/dev/null || true
    [ -z "$APP_PID" ] || kill "$APP_PID" 2>/dev/null || true
    kill "$COMP_PID" 2>/dev/null || true
    rm -rf "$CONF"
}
trap cleanup EXIT

nested_x=""
for _ in $(seq 1 150); do
    sleep 0.2
    kill -0 "$COMP_PID" 2>/dev/null
    for d in $(seq 2 9); do
        if [ -z "${before[$d]:-}" ] && DISPLAY=":$d" "$BIN" probe 2>/dev/null; then
            nested_x=$d
            break 2
        fi
    done
done
[ -n "$nested_x" ]

nested_wayland=""
for _ in $(seq 1 100); do
    nested_wayland=$(sed -n 's/.*Listening on "\(wayland-[0-9][0-9]*\)".*/\1/p' "$LOG" | tail -1)
    [ -n "$nested_wayland" ] && break
    sleep 0.1
done
[ -n "$nested_wayland" ]

HOST_INFO=$(DISPLAY=:1 "$FOCUS_HELPER" COSMIC)
HOST_W=$(sed -n 's/.* size=\([0-9][0-9]*\)x[0-9][0-9]* .*/\1/p' <<<"$HOST_INFO")
HOST_H=$(sed -n 's/.* size=[0-9][0-9]*x\([0-9][0-9]*\) .*/\1/p' <<<"$HOST_INFO")
[ -n "$HOST_W" ] && [ -n "$HOST_H" ]

DISPLAY=":$nested_x" "$BIN" hover-fresh-lock >"$APP_LOG" 2>&1 &
APP_PID=$!
for _ in $(seq 1 120); do
    rg -q '^HOVER_FRESH_READY ' "$APP_LOG" && break
    kill -0 "$APP_PID" 2>/dev/null
    sleep 0.1
done
if ! rg -q '^HOVER_FRESH_READY ' "$APP_LOG"; then
    cat "$APP_LOG"
    echo "PRECONDITION_FAIL fresh-lock target never became ready" >&2
    exit 2
fi

READY=$(rg '^HOVER_FRESH_READY ' "$APP_LOG" | tail -1)
TARGET_X=$(sed -n 's/.* x=\([-0-9][0-9]*\) .*/\1/p' <<<"$READY")
TARGET_Y=$(sed -n 's/.* y=\([-0-9][0-9]*\) .*/\1/p' <<<"$READY")
TARGET_W=$(sed -n 's/.* w=\([0-9][0-9]*\) .*/\1/p' <<<"$READY")
TARGET_H=$(sed -n 's/.* h=\([0-9][0-9]*\)$/\1/p' <<<"$READY")
[ -n "$TARGET_X" ] && [ -n "$TARGET_Y" ] && [ -n "$TARGET_W" ] && [ -n "$TARGET_H" ]
SCREEN_W=$((TARGET_X + TARGET_W + 20))
SCREEN_H=$((TARGET_Y + TARGET_H + 20))

env -u DISPLAY WAYLAND_DISPLAY="$nested_wayland" \
    alacritty --title COSMIC-native-fresh-focus \
    -o window.dimensions.columns=28 -o window.dimensions.lines=8 \
    >/tmp/cosmic-native-fresh-focus.log 2>&1 &
NATIVE_PID=$!

for _ in $(seq 1 100); do
    rg -q '^HOVER_FRESH_NATIVE_FOCUS$' "$APP_LOG" && break
    kill -0 "$NATIVE_PID" 2>/dev/null || break
    sleep 0.1
done
if ! rg -q '^HOVER_FRESH_NATIVE_FOCUS$' "$APP_LOG"; then
    cat "$APP_LOG"
    cat /tmp/cosmic-native-fresh-focus.log >&2 || true
    echo "PRECONDITION_FAIL native Wayland focus was not observed" >&2
    exit 2
fi

OFF=$(( $(wc -c <"$LOG") + 1 ))

# Force a leave and then hover into the X11 target without activating or
# clicking the nested compositor window.
HOST_OUT_X=$((40 * HOST_W / SCREEN_W))
HOST_OUT_Y=$((40 * HOST_H / SCREEN_H))
HOST_TARGET_X=$(((TARGET_X + TARGET_W / 2) * HOST_W / SCREEN_W))
HOST_TARGET_Y=$(((TARGET_Y + TARGET_H / 2) * HOST_H / SCREEN_H))

DISPLAY=:1 "$FOCUS_HELPER" --warp-window COSMIC "$HOST_OUT_X" "$HOST_OUT_Y" >/dev/null
sleep 0.15
DISPLAY=:1 "$FOCUS_HELPER" --warp-window COSMIC \
    "$HOST_TARGET_X" "$HOST_TARGET_Y" >/dev/null

for _ in $(seq 1 80); do
    rg -q '^HOVER_FRESH_WARP_DONE$' "$APP_LOG" && break
    sleep 0.1
done
if ! rg -q '^HOVER_FRESH_WARP_DONE$' "$APP_LOG"; then
    cat "$APP_LOG"
    echo "PRECONDITION_FAIL fresh-lock warp sequence did not finish" >&2
    exit 2
fi

sleep 0.2
SEG=$(tail -c "+$OFF" "$LOG")
IDS=$(rg -o 'zwp_pointer_constraints_v1@[0-9]+\.lock_pointer, \([0-9]+' <<<"$SEG" \
    | rg -o '[0-9]+$' | sort -u || true)

DISPLAY=":$nested_x" "$FOCUS_HELPER" --query-focus
echo "HOVER_FRESH_TRIGGERED=1"
if [ -n "$IDS" ]; then
    echo "FRESH_LOCK_REQUEST=1 ids=$(tr '\n' ',' <<<"$IDS" | sed 's/,$//')"
else
    echo "FRESH_LOCK_REQUEST=0"
fi

activated=0
for id in $IDS; do
    if rg -q "zwp_locked_pointer_v1@$id\.locked" <<<"$SEG"; then
        activated=1
        break
    fi
done
echo "FRESH_LOCK_ACTIVATED_UNFOCUSED=$activated"

cat "$APP_LOG"
echo "--- fresh-lock pointer protocol ---"
rg -n 'lock_pointer|locked\(|unlocked\(|wl_keyboard@[0-9]+\.(enter|leave)|wl_pointer@[0-9]+\.(enter|leave)' <<<"$SEG" | tail -160 || true

[ -n "$IDS" ] || exit 2
[ "$activated" -eq "$EXPECT_ACTIVATED_UNFOCUSED" ] || exit 1
