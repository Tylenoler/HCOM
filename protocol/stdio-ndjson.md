# HCOM Core IPC v1 — NDJSON over stdio

Phase 1 fixes the front/back boundary, not the serial implementation. Flutter launches `hcom-core` as a child process and exchanges one UTF-8 JSON object per line. `stdout` is reserved for protocol events; human diagnostics must go to `stderr`.

## Commands: Flutter → Rust

```json
{"command":"hello","payload":{"client":"flutter","protocolVersion":1}}
{"command":"ping","payload":{}}
{"command":"open_port","payload":{"port":"COM3","baudRate":115200}}
{"command":"close_port","payload":{}}
```

`open_port` and `close_port` are reserved in Phase 1; their COM implementation is Phase 2.

## Events: Rust → Flutter

```json
{"event":"ready","payload":{"protocolVersion":1,"coreVersion":"0.1.0"}}
{"event":"pong","payload":{}}
{"event":"serial_data","payload":{"direction":"rx","timestamp":"2026-09-10T12:00:00.000Z","bytes":"AA 55"}}
{"event":"connection_state","payload":{"state":"disconnected"}}
{"event":"error","payload":{"code":"unsupported","message":"..."}}
```

Messages must be independently parseable, ordered on the child-process stream, and bounded. Backpressure and batching rules are deliberately deferred until serial throughput is measured in Phase 2.
