# HCOM Core IPC v1 — NDJSON over stdio

Phase 2 implements the Windows UART core behind the Phase 1 process boundary. Flutter launches `hcom-core` as a child process and exchanges one UTF-8 JSON object per line. `stdout` is reserved for protocol events; human diagnostics must go to `stderr`.

## Commands: Flutter → Rust

```json
{"command":"hello","payload":{"client":"flutter","protocolVersion":1}}
{"command":"ping","payload":{}}
{"command":"scan_ports","payload":{}}
{"command":"open_port","payload":{"port":"COM3","baudRate":115200,"dataBits":8,"stopBits":1,"parity":"none","flowControl":"none"}}
{"command":"close_port","payload":{}}
{"command":"write_data","payload":{"bytes":"AA 55 01 00"}}
```

`open_port` maps the selected settings to the native Windows COM handle. The Core accepts `none` / `odd` / `even` parity and `none` / `rts_cts` / `xon_xoff` flow control. The Flutter client must wait for `connection_state: connected` before allowing `write_data`.

## Events: Rust → Flutter

```json
{"event":"ready","payload":{"protocolVersion":1,"coreVersion":"0.1.0"}}
{"event":"pong","payload":{}}
{"event":"ports","payload":{"ports":[{"port":"COM3","description":"USB Serial Device","hardwareId":"USB\\VID_1A86&PID_7523","kind":"usb"}]}}
{"event":"serial_data","payload":{"direction":"rx","timestamp":"2026-09-10T12:00:00.000Z","bytes":"AA 55"}}
{"event":"connection_state","payload":{"state":"connecting|connected|error|disconnected","port":"COM3"}}
{"event":"error","payload":{"code":"unsupported","message":"..."}}
```

Messages are independently parseable and ordered on the child-process stream. UART is a byte stream, so the Core coalesces short reads and submits a display batch after 12ms of RX idle time (or on reaching 4KiB); this is a display boundary, not a protocol frame. RX uses a bounded queue of 128 events and never blocks the serial reader. When the consumer cannot keep up, newest batches are discarded and the next delivered batch includes `droppedBytes`, followed by a `backpressure` error event. Single writes are capped at 16KiB.
