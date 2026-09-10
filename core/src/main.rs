//! Phase 1 stdio IPC spike. Serial access arrives in Phase 2.

use std::io::{self, BufRead, Write};

fn event(name: &str, payload: &str) {
    println!(r#"{{"event":"{}","payload":{}}}"#, name, payload);
    let _ = io::stdout().flush();
}

fn main() {
    event("ready", r#"{"protocolVersion":1,"coreVersion":"0.1.0"}"#);
    event("connection_state", r#"{"state":"disconnected"}"#);

    for line in io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        // Avoid a JSON dependency in the Phase 1 executable spike. The Dart
        // side owns validation; Phase 2 will introduce typed command parsing.
        if line.contains(r#""command":"ping""#) {
            event("pong", "{}");
        } else if line.contains(r#""command":"hello""#) {
            event("connection_state", r#"{"state":"disconnected"}"#);
        } else {
            event(
                "error",
                r#"{"code":"unsupported","message":"Command is reserved for a later phase."}"#,
            );
        }
    }
}
