//! Scenario driver for cosmic-comp's pointer-lock activation bugs with X11
//! games (Xwayland pointer warp emulation).
//!
//! A game in mouse-look mode hides the cursor, grabs the pointer and warps it
//! back to center every frame, reading relative deltas. That makes Xwayland
//! request a pointer lock (`zwp_pointer_constraints_v1.lock_pointer`) on the
//! game's surface; relative motion only reaches the game once the compositor
//! *activates* that lock and replies `zwp_locked_pointer_v1.locked`.
//!
//! This binary only sets up the X11-side scenarios. The verdict is read off
//! the compositor's WAYLAND_DEBUG log by run-tests.sh, because the obvious
//! behavioural probe does not work: while a warp emulator exists Xwayland
//! tracks a *fake* pointer position internally, so XQueryPointer reports the
//! warped-to position whether or not the compositor honoured the lock.
//!
//! Scenarios:
//!   dummy      map a small managed window and idle (holds keyboard focus)
//!   baseline   managed fullscreen window grabs pointer and warps
//!   or-grab    override-redirect fullscreen window grabs the pointer while
//!              another X11 window holds keyboard focus (Helldivers 2 "3D
//!              mode" shape)
//!   fs-toggle  grab and warp, then toggle fullscreen off/on, exercising the
//!              focus-target transitions that can destroy an active lock
//!   focus-away-grabbed
//!              keep the game's X pointer grab active while another managed
//!              window becomes active (KCD2 alt-tab shape)
//!   focus-cycle
//!              release the game's grab/cursor hide on focus-out, then
//!              reacquire both after focusing the game again (Cyberpunk shape)
//!   startup-*
//!              small first-launch ordering probes used to reproduce the
//!              deterministic Cyberpunk failure from a fresh Xwayland session

use std::{process::exit, thread::sleep, time::Duration};

use x11rb::connection::Connection;
use x11rb::protocol::xfixes::ConnectionExt as XFixesExt;
use x11rb::protocol::xproto::*;
use x11rb::wrapper::ConnectionExt as _;
use x11rb::{COPY_DEPTH_FROM_PARENT, CURRENT_TIME};

type Conn = x11rb::rust_connection::RustConnection;

struct Ctx {
    conn: Conn,
    root: Window,
    screen_w: u16,
    screen_h: u16,
}

fn connect() -> Ctx {
    let (conn, screen_num) = x11rb::connect(None).unwrap_or_else(|e| {
        eprintln!("cannot connect to X display: {e}");
        exit(2);
    });
    let screen = &conn.setup().roots[screen_num];
    Ctx {
        root: screen.root,
        screen_w: screen.width_in_pixels,
        screen_h: screen.height_in_pixels,
        conn,
    }
}

fn create_window(ctx: &Ctx, or: bool, w: u16, h: u16, pixel: u32, title: &str) -> Window {
    let win = ctx.conn.generate_id().unwrap();
    ctx.conn
        .create_window(
            COPY_DEPTH_FROM_PARENT,
            win,
            ctx.root,
            0,
            0,
            w,
            h,
            0,
            WindowClass::INPUT_OUTPUT,
            0,
            &CreateWindowAux::new()
                .override_redirect(if or { 1 } else { 0 })
                .background_pixel(pixel)
                .event_mask(EventMask::STRUCTURE_NOTIFY | EventMask::POINTER_MOTION),
        )
        .unwrap();
    ctx.conn
        .change_property8(
            PropMode::REPLACE,
            win,
            AtomEnum::WM_NAME,
            AtomEnum::STRING,
            title.as_bytes(),
        )
        .unwrap();
    ctx.conn.map_window(win).unwrap();
    ctx.conn.flush().unwrap();
    win
}

/// Round-trip to the X server, then wait for the compositor to finish
/// mapping/laying out what we just did.
fn settle(ctx: &Ctx, ms: u64) {
    ctx.conn.get_input_focus().unwrap().reply().ok();
    sleep(Duration::from_millis(ms));
}

fn atom(ctx: &Ctx, name: &str) -> Atom {
    ctx.conn
        .intern_atom(false, name.as_bytes())
        .unwrap()
        .reply()
        .unwrap()
        .atom
}

fn set_fullscreen(ctx: &Ctx, win: Window, on: bool) {
    let wm_state = atom(ctx, "_NET_WM_STATE");
    let fs = atom(ctx, "_NET_WM_STATE_FULLSCREEN");
    let ev = ClientMessageEvent::new(32, win, wm_state, [on as u32, fs, 0, 0, 0]);
    ctx.conn
        .send_event(
            false,
            ctx.root,
            EventMask::SUBSTRUCTURE_REDIRECT | EventMask::SUBSTRUCTURE_NOTIFY,
            ev,
        )
        .unwrap();
    ctx.conn.flush().unwrap();
}

fn activate_window(ctx: &Ctx, win: Window) {
    let active = atom(ctx, "_NET_ACTIVE_WINDOW");
    let ev = ClientMessageEvent::new(32, win, active, [1, CURRENT_TIME, 0, 0, 0]);
    ctx.conn
        .send_event(
            false,
            ctx.root,
            EventMask::SUBSTRUCTURE_REDIRECT | EventMask::SUBSTRUCTURE_NOTIFY,
            ev,
        )
        .unwrap();
    ctx.conn.flush().unwrap();
}

fn wait_input_focus(ctx: &Ctx, win: Window) -> bool {
    for _ in 0..30 {
        if ctx
            .conn
            .get_input_focus()
            .unwrap()
            .reply()
            .is_ok_and(|reply| reply.focus == win)
        {
            return true;
        }
        sleep(Duration::from_millis(100));
    }
    false
}

fn wait_fullscreen_size(ctx: &Ctx, win: Window) -> bool {
    for _ in 0..30 {
        let geo = ctx.conn.get_geometry(win).unwrap().reply().unwrap();
        if geo.width >= ctx.screen_w - 2 && geo.height >= ctx.screen_h - 2 {
            return true;
        }
        sleep(Duration::from_millis(100));
    }
    false
}

/// Hide the cursor and grab the pointer, as a game entering mouse-look does.
/// Both are preconditions for Xwayland's warp emulation (it bails out while
/// an X cursor is visible).
fn hide_and_grab(ctx: &Ctx, win: Window) {
    ctx.conn
        .xfixes_query_version(4, 0)
        .unwrap()
        .reply()
        .unwrap();
    ctx.conn.xfixes_hide_cursor(win).unwrap();
    let status = ctx
        .conn
        .grab_pointer(
            true,
            win,
            EventMask::POINTER_MOTION | EventMask::BUTTON_PRESS | EventMask::BUTTON_RELEASE,
            GrabMode::ASYNC,
            GrabMode::ASYNC,
            x11rb::NONE,
            x11rb::NONE,
            CURRENT_TIME,
        )
        .unwrap()
        .reply()
        .unwrap()
        .status;
    if status != GrabStatus::SUCCESS {
        eprintln!("XGrabPointer failed: {status:?}");
        exit(2);
    }
    ctx.conn.flush().unwrap();
}

fn show_and_ungrab(ctx: &Ctx, win: Window) {
    ctx.conn.ungrab_pointer(CURRENT_TIME).unwrap();
    ctx.conn.xfixes_show_cursor(win).unwrap();
    ctx.conn.flush().unwrap();
}

/// Recenter the pointer a few times, the way a mouse-look game does every
/// frame. This is what drives Xwayland to request the pointer lock.
fn warp_loop(ctx: &Ctx, rounds: usize) {
    let (cx, cy) = (ctx.screen_w as i16 / 2, ctx.screen_h as i16 / 2);
    for i in 0..rounds {
        let (tx, ty) = if i % 2 == 0 {
            (cx, cy)
        } else {
            (cx - 17, cy - 11)
        };
        ctx.conn
            .warp_pointer(x11rb::NONE, ctx.root, 0, 0, 0, 0, tx, ty)
            .unwrap();
        ctx.conn.flush().unwrap();
        sleep(Duration::from_millis(150));
    }
}

fn warp_to(ctx: &Ctx, win: Window, x: i16, y: i16) {
    ctx.conn
        .warp_pointer(x11rb::NONE, win, 0, 0, 0, 0, x, y)
        .unwrap();
    ctx.conn.flush().unwrap();
    settle(ctx, 150);
}

fn unmap_remap(ctx: &Ctx, win: Window, ms: u64) {
    ctx.conn.unmap_window(win).unwrap();
    ctx.conn.flush().unwrap();
    settle(ctx, ms);
    ctx.conn.map_window(win).unwrap();
    ctx.conn.flush().unwrap();
    settle(ctx, ms);
}

fn main() {
    let mode = std::env::args().nth(1).unwrap_or_default();
    let ctx = connect();

    match mode.as_str() {
        "dummy" => {
            create_window(&ctx, false, 320, 200, 0x0060_60ff, "focus-dummy");
            println!("managed window mapped, holding keyboard focus; idling");
            loop {
                sleep(Duration::from_secs(3600));
            }
        }
        "baseline" => {
            let win = create_window(&ctx, false, 640, 480, 0x0020_a020, "baseline-game");
            sleep(Duration::from_millis(500));
            set_fullscreen(&ctx, win, true);
            if !wait_fullscreen_size(&ctx, win) {
                eprintln!("window never became fullscreen");
                exit(2);
            }
            sleep(Duration::from_millis(300));
            hide_and_grab(&ctx, win);
            warp_loop(&ctx, 8);
        }
        "or-grab" => {
            // Both windows come from this one process, sequentially: a
            // separate focus-holder process races with this one for pointer
            // focus, because its surface can land in the scene at any moment.
            create_window(&ctx, false, 640, 480, 0x0060_60ff, "or-focus-holder");
            settle(&ctx, 2500);

            let win = create_window(
                &ctx,
                true,
                ctx.screen_w,
                ctx.screen_h,
                0x00a0_2020,
                "or-game",
            );
            ctx.conn
                .configure_window(win, &ConfigureWindowAux::new().stack_mode(StackMode::ABOVE))
                .unwrap();
            ctx.conn.flush().unwrap();
            settle(&ctx, 1500);

            hide_and_grab(&ctx, win);
            warp_loop(&ctx, 8);
        }
        "fs-toggle" => {
            let win = create_window(&ctx, false, 640, 480, 0x0020_a020, "fs-toggle-game");
            sleep(Duration::from_millis(500));
            set_fullscreen(&ctx, win, true);
            if !wait_fullscreen_size(&ctx, win) {
                eprintln!("window never became fullscreen");
                exit(2);
            }
            sleep(Duration::from_millis(300));
            hide_and_grab(&ctx, win);
            warp_loop(&ctx, 4);
            // leave and re-enter fullscreen, warping throughout
            set_fullscreen(&ctx, win, false);
            sleep(Duration::from_millis(600));
            warp_loop(&ctx, 4);
            set_fullscreen(&ctx, win, true);
            sleep(Duration::from_millis(600));
            warp_loop(&ctx, 4);
        }
        "focus-away-grabbed" => {
            let other = create_window(&ctx, false, 640, 480, 0x0060_60ff, "other-app");
            settle(&ctx, 500);

            let game = create_window(&ctx, false, 640, 480, 0x0020_a020, "kcd2-game");
            settle(&ctx, 500);
            set_fullscreen(&ctx, game, true);
            if !wait_fullscreen_size(&ctx, game) {
                eprintln!("game never became fullscreen");
                exit(2);
            }
            activate_window(&ctx, game);
            settle(&ctx, 500);
            if !wait_input_focus(&ctx, game) {
                eprintln!("game never received X input focus");
                exit(2);
            }
            hide_and_grab(&ctx, game);
            warp_loop(&ctx, 4);

            // Alt-tab shape: keyboard focus moves to another application while
            // the game leaves its pointer grab active.
            activate_window(&ctx, other);
            settle(&ctx, 700);
            if !wait_input_focus(&ctx, other) {
                eprintln!("other window never received X input focus");
                exit(2);
            }
            warp_loop(&ctx, 4);
        }
        "focus-cycle" => {
            let other = create_window(&ctx, false, 640, 480, 0x0060_60ff, "other-app");
            settle(&ctx, 500);

            let game = create_window(&ctx, false, 640, 480, 0x0020_a020, "cyberpunk-game");
            settle(&ctx, 500);
            set_fullscreen(&ctx, game, true);
            if !wait_fullscreen_size(&ctx, game) {
                eprintln!("game never became fullscreen");
                exit(2);
            }
            activate_window(&ctx, game);
            settle(&ctx, 500);
            if !wait_input_focus(&ctx, game) {
                eprintln!("game never received initial X input focus");
                exit(2);
            }
            hide_and_grab(&ctx, game);
            warp_loop(&ctx, 4);

            // Typical game focus-out path: another app becomes focused first,
            // then the game reacts to FocusOut by exposing the cursor and
            // dropping its X pointer grab.
            activate_window(&ctx, other);
            if !wait_input_focus(&ctx, other) {
                eprintln!("other window never received X input focus");
                exit(2);
            }
            show_and_ungrab(&ctx, game);
            settle(&ctx, 250);

            // Focus the game again and re-enter mouse-look.
            activate_window(&ctx, game);
            if !wait_input_focus(&ctx, game) {
                eprintln!("game never regained X input focus");
                exit(2);
            }
            settle(&ctx, 100);
            hide_and_grab(&ctx, game);
            warp_loop(&ctx, 6);
        }
        "startup-grab-before-fs" => {
            let game = create_window(&ctx, false, 640, 480, 0x0020_a020, "startup-game");
            settle(&ctx, 300);
            activate_window(&ctx, game);
            wait_input_focus(&ctx, game);
            hide_and_grab(&ctx, game);
            warp_loop(&ctx, 3);
            set_fullscreen(&ctx, game, true);
            settle(&ctx, 500);
            warp_loop(&ctx, 8);
        }
        "startup-grab-before-focus" => {
            let other = create_window(&ctx, false, 640, 480, 0x0060_60ff, "startup-other");
            settle(&ctx, 400);
            activate_window(&ctx, other);
            wait_input_focus(&ctx, other);
            let game = create_window(&ctx, false, 640, 480, 0x0020_a020, "startup-game");
            settle(&ctx, 200);
            hide_and_grab(&ctx, game);
            warp_loop(&ctx, 3);
            set_fullscreen(&ctx, game, true);
            settle(&ctx, 300);
            activate_window(&ctx, game);
            wait_input_focus(&ctx, game);
            warp_loop(&ctx, 8);
        }
        "startup-fs-before-focus" => {
            let other = create_window(&ctx, false, 640, 480, 0x0060_60ff, "startup-other");
            settle(&ctx, 400);
            activate_window(&ctx, other);
            wait_input_focus(&ctx, other);
            let game = create_window(&ctx, false, 640, 480, 0x0020_a020, "startup-game");
            settle(&ctx, 200);
            set_fullscreen(&ctx, game, true);
            if !wait_fullscreen_size(&ctx, game) {
                eprintln!("game never became fullscreen");
                exit(2);
            }
            hide_and_grab(&ctx, game);
            warp_loop(&ctx, 4);
            activate_window(&ctx, game);
            wait_input_focus(&ctx, game);
            warp_loop(&ctx, 8);
        }
        "startup-remap-before-grab" => {
            let game = create_window(&ctx, false, 640, 480, 0x0020_a020, "startup-game");
            settle(&ctx, 300);
            set_fullscreen(&ctx, game, true);
            wait_fullscreen_size(&ctx, game);
            unmap_remap(&ctx, game, 250);
            set_fullscreen(&ctx, game, true);
            settle(&ctx, 350);
            activate_window(&ctx, game);
            wait_input_focus(&ctx, game);
            hide_and_grab(&ctx, game);
            warp_loop(&ctx, 8);
        }
        "startup-remap-after-grab" => {
            let game = create_window(&ctx, false, 640, 480, 0x0020_a020, "startup-game");
            settle(&ctx, 300);
            set_fullscreen(&ctx, game, true);
            wait_fullscreen_size(&ctx, game);
            activate_window(&ctx, game);
            wait_input_focus(&ctx, game);
            hide_and_grab(&ctx, game);
            warp_loop(&ctx, 3);
            unmap_remap(&ctx, game, 250);
            set_fullscreen(&ctx, game, true);
            settle(&ctx, 350);
            activate_window(&ctx, game);
            wait_input_focus(&ctx, game);
            warp_loop(&ctx, 8);
        }
        "startup-focus-churn" => {
            let other = create_window(&ctx, false, 640, 480, 0x0060_60ff, "startup-other");
            settle(&ctx, 300);
            let game = create_window(&ctx, false, 640, 480, 0x0020_a020, "startup-game");
            settle(&ctx, 300);
            set_fullscreen(&ctx, game, true);
            wait_fullscreen_size(&ctx, game);
            activate_window(&ctx, game);
            wait_input_focus(&ctx, game);
            activate_window(&ctx, other);
            wait_input_focus(&ctx, other);
            activate_window(&ctx, game);
            wait_input_focus(&ctx, game);
            hide_and_grab(&ctx, game);
            warp_loop(&ctx, 8);
        }
        "startup-focus-churn-grabbed" => {
            let other = create_window(&ctx, false, 640, 480, 0x0060_60ff, "startup-other");
            settle(&ctx, 300);
            let game = create_window(&ctx, false, 640, 480, 0x0020_a020, "startup-game");
            settle(&ctx, 300);
            set_fullscreen(&ctx, game, true);
            wait_fullscreen_size(&ctx, game);
            activate_window(&ctx, game);
            wait_input_focus(&ctx, game);
            hide_and_grab(&ctx, game);
            warp_loop(&ctx, 3);
            activate_window(&ctx, other);
            wait_input_focus(&ctx, other);
            activate_window(&ctx, game);
            wait_input_focus(&ctx, game);
            warp_loop(&ctx, 8);
        }
        "startup-launcher-to-game" => {
            let launcher = create_window(&ctx, false, 900, 600, 0x0060_60ff, "startup-launcher");
            settle(&ctx, 400);
            activate_window(&ctx, launcher);
            wait_input_focus(&ctx, launcher);
            let game = create_window(&ctx, false, 640, 480, 0x0020_a020, "startup-game");
            settle(&ctx, 150);
            activate_window(&ctx, game);
            wait_input_focus(&ctx, game);
            hide_and_grab(&ctx, game);
            warp_loop(&ctx, 2);
            set_fullscreen(&ctx, game, true);
            settle(&ctx, 500);
            warp_loop(&ctx, 8);
        }
        "startup-stale-pointer-focus" => {
            // Force the Wayland pointer onto a different X11 surface first.
            // The game then arms relative mode while windowed/off-pointer.
            // Making it fullscreen changes which surface is geometrically
            // under the stationary pointer; a compositor must refresh pointer
            // focus so Xwayland can engage warp emulation on the first warp.
            let other = create_window(&ctx, false, 640, 480, 0x0060_60ff, "startup-other");
            settle(&ctx, 250);
            set_fullscreen(&ctx, other, true);
            wait_fullscreen_size(&ctx, other);
            activate_window(&ctx, other);
            wait_input_focus(&ctx, other);
            warp_to(
                &ctx,
                ctx.root,
                ctx.screen_w.saturating_sub(40) as i16,
                ctx.screen_h.saturating_sub(40) as i16,
            );

            let game = create_window(&ctx, false, 320, 240, 0x0020_a020, "startup-game");
            settle(&ctx, 250);
            activate_window(&ctx, other);
            wait_input_focus(&ctx, other);

            // Arm the same X11 grab/cursor-hide state used by mouse-look, but
            // do not warp yet: the Wayland pointer still belongs to `other`.
            hide_and_grab(&ctx, game);
            settle(&ctx, 150);

            set_fullscreen(&ctx, game, true);
            wait_fullscreen_size(&ctx, game);
            activate_window(&ctx, game);
            wait_input_focus(&ctx, game);
            settle(&ctx, 250);
            warp_loop(&ctx, 10);
        }
        // exit 0 iff $DISPLAY accepts connections (used by run-tests.sh to
        // find the nested Xwayland among stale sockets)
        "probe" => exit(0),
        _ => {
            eprintln!(
                "usage: pointer-lock-test <dummy|baseline|or-grab|fs-toggle|focus-away-grabbed|focus-cycle|startup-*|probe>"
            );
            exit(2);
        }
    }
}
