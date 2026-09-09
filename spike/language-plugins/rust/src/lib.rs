//! The spike behavior, Rust edition (native-compiled family).
//!
//! Mirrors scripts/behavior.lua exactly — the host asserts both worlds
//! end identical. Zero crates: the point is the raw C-ABI contract
//! (contract/contract.h) consumed as plain `extern "C"` declarations, the
//! way a real labelle-rust build integration would generate them.

use std::os::raw::c_char;

extern "C" {
    fn labelle_entity_create() -> u64;
    fn labelle_component_set(id: u64, name: *const c_char, name_len: usize, json: *const c_char, json_len: usize);
    fn labelle_component_get(id: u64, name: *const c_char, name_len: usize, out: *mut c_char, out_cap: usize) -> usize;
    fn labelle_event_emit(name: *const c_char, name_len: usize, json: *const c_char, json_len: usize);
    fn labelle_log(msg: *const c_char, len: usize);
    fn labelle_event_subscribe(name: *const c_char, name_len: usize);
    fn labelle_event_poll(out: *mut c_char, out_cap: usize) -> usize;
}

fn set(id: u64, name: &str, json: &str) {
    unsafe {
        labelle_component_set(
            id,
            name.as_ptr() as *const c_char,
            name.len(),
            json.as_ptr() as *const c_char,
            json.len(),
        )
    }
}

fn get(id: u64, name: &str) -> String {
    let mut buf = [0u8; 192];
    let len = unsafe {
        labelle_component_get(
            id,
            name.as_ptr() as *const c_char,
            name.len(),
            buf.as_mut_ptr() as *mut c_char,
            buf.len(),
        )
    };
    String::from_utf8_lossy(&buf[..len]).into_owned()
}

fn emit(name: &str, json: &str) {
    unsafe {
        labelle_event_emit(
            name.as_ptr() as *const c_char,
            name.len(),
            json.as_ptr() as *const c_char,
            json.len(),
        )
    }
}

fn log(msg: &str) {
    unsafe { labelle_log(msg.as_ptr() as *const c_char, msg.len()) }
}

// POC-only global; a real labelle-rust hands scripts a context struct.
static mut PLAYER: u64 = 0;

#[no_mangle]
pub extern "C" fn rust_script_init() {
    let player = unsafe { labelle_entity_create() };
    unsafe { PLAYER = player };
    set(player, "Position", "{\"x\":0,\"y\":0}");
    unsafe {
        labelle_event_subscribe("tick_started".as_ptr() as *const c_char, "tick_started".len())
    };
    log(&format!("rust: player {} ready", player));
}

#[no_mangle]
pub extern "C" fn rust_script_update(_dt: f32) {
    let player = unsafe { PLAYER };
    // Receive side: drain the inbox the host filled before this tick.
    loop {
        let mut buf = [0u8; 224];
        let len = unsafe { labelle_event_poll(buf.as_mut_ptr() as *mut c_char, buf.len()) };
        if len == 0 {
            break;
        }
        let ev = String::from_utf8_lossy(&buf[..len]).into_owned();
        if ev.contains("\"n\":4") {
            set(player, "TickLog", "{\"last\":4}");
            log("rust: saw tick 4");
        }
    }
    let json = get(player, "Position");
    // Parse `"x":<n>` without a JSON crate — mirrors the Lua string.match.
    let x: i64 = json
        .split("\"x\":")
        .nth(1)
        .and_then(|s| {
            s.chars()
                .take_while(|c| c.is_ascii_digit() || *c == '-')
                .collect::<String>()
                .parse()
                .ok()
        })
        .unwrap_or(0);
    let x = x + 10;
    set(player, "Position", &format!("{{\"x\":{},\"y\":0}}", x));

    if x == 30 {
        unsafe {
            let bullet = labelle_entity_create();
            set(bullet, "Bullet", "{\"vx\":0,\"vy\":-500}");
            emit("bullet_spawned", &format!("{{\"owner\":{}}}", player));
            log("rust: bullet away");
        }
    }
}
