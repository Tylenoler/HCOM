//! HCOM Phase 2 serial core. The stdio protocol remains the process boundary;
//! serial I/O stays on Rust threads so the Flutter event loop is never blocked.

use std::{
    io::{self, BufRead, Read, Write},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Receiver, RecvTimeoutError, SyncSender, TrySendError},
        Arc,
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

use chrono::{SecondsFormat, Utc};
use serde::Deserialize;
use serde_json::{json, Value};
use serialport::{
    DataBits, FlowControl, Parity, SerialPort, SerialPortInfo, SerialPortType, StopBits,
};

const READ_BUFFER_BYTES: usize = 1024;
const MAX_BATCH_BYTES: usize = 4 * 1024;
const MAX_EVENT_QUEUE: usize = 128;
const MAX_WRITE_BYTES: usize = 16 * 1024;
const RX_IDLE_BOUNDARY: Duration = Duration::from_millis(6);

#[derive(Debug, Deserialize)]
struct Command {
    command: String,
    #[serde(default)]
    payload: Value,
}

enum CoreEvent {
    Command(Result<Command, String>),
    InputClosed,
    SerialData {
        session: u64,
        bytes: Vec<u8>,
        timestamp: String,
        dropped_bytes: u64,
    },
    SerialFault {
        session: u64,
        message: String,
    },
}

struct PortSession {
    id: u64,
    port: Box<dyn SerialPort>,
    stop: Arc<AtomicBool>,
    reader: JoinHandle<()>,
}

struct PeriodicSend {
    interval: Duration,
    commands: Vec<Vec<u8>>,
    next_due: Instant,
}

/// UART is a byte stream: a single write may be returned by the operating
/// system in several arbitrary reads. Keep bytes until a brief idle interval
/// gives the workbench a useful display unit, without pretending it is a
/// protocol frame (that belongs to Phase 3).
#[derive(Default)]
struct PendingRx {
    bytes: Vec<u8>,
    timestamp: Option<String>,
}

impl PendingRx {
    fn append(&mut self, bytes: &[u8], received_at: String) {
        if self.bytes.is_empty() {
            self.timestamp = Some(received_at);
        }
        self.bytes.extend_from_slice(bytes);
    }

    fn take(&mut self) -> Option<(Vec<u8>, String)> {
        if self.bytes.is_empty() {
            return None;
        }
        Some((
            std::mem::take(&mut self.bytes),
            self.timestamp.take().unwrap_or_else(timestamp),
        ))
    }
}

fn timestamp() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true)
}

fn emit(name: &str, payload: Value) {
    // stdout is exclusively a machine-readable, line-delimited protocol.
    println!("{}", json!({"event": name, "payload": payload}));
    let _ = io::stdout().flush();
}

fn emit_error(code: &str, message: impl Into<String>) {
    emit("error", json!({"code": code, "message": message.into()}));
}

fn emit_state(state: &str, port: Option<&str>) {
    let mut payload = json!({"state": state});
    if let Some(port) = port {
        payload["port"] = Value::String(port.to_owned());
    }
    emit("connection_state", payload);
}

fn hex(bytes: &[u8]) -> String {
    bytes
        .iter()
        .map(|byte| format!("{byte:02X}"))
        .collect::<Vec<_>>()
        .join(" ")
}

fn parse_hex(value: &str) -> Result<Vec<u8>, String> {
    let compact: String = value.chars().filter(|ch| !ch.is_whitespace()).collect();
    if compact.is_empty() {
        return Err("发送内容不能为空。".to_owned());
    }
    if compact.len() % 2 != 0 {
        return Err("HEX 字节数必须为偶数。".to_owned());
    }
    if compact.len() / 2 > MAX_WRITE_BYTES {
        return Err(format!("单次发送最多 {MAX_WRITE_BYTES} 字节。"));
    }
    (0..compact.len())
        .step_by(2)
        .map(|index| {
            u8::from_str_radix(&compact[index..index + 2], 16)
                .map_err(|_| format!("无效 HEX 字节：{}", &compact[index..index + 2]))
        })
        .collect()
}

fn port_details(port: &SerialPortInfo) -> Value {
    let (description, hardware_id, kind) = match &port.port_type {
        SerialPortType::UsbPort(usb) => {
            let description = usb
                .product
                .clone()
                .unwrap_or_else(|| "USB Serial Device".to_owned());
            let serial = usb
                .serial_number
                .as_deref()
                .map(|value| format!("&SN_{value}"))
                .unwrap_or_default();
            (
                description,
                format!("USB\\VID_{:04X}&PID_{:04X}{serial}", usb.vid, usb.pid),
                "usb",
            )
        }
        SerialPortType::BluetoothPort => (
            "Bluetooth Serial Port".to_owned(),
            "Bluetooth".to_owned(),
            "bluetooth",
        ),
        SerialPortType::PciPort => ("PCI Serial Port".to_owned(), "PCI".to_owned(), "pci"),
        SerialPortType::Unknown => ("Serial Port".to_owned(), "Unknown".to_owned(), "serial"),
    };
    json!({
        "port": port.port_name,
        "description": description,
        "hardwareId": hardware_id,
        "kind": kind,
    })
}

fn scan_ports() {
    match serialport::available_ports() {
        Ok(ports) => emit(
            "ports",
            json!({"ports": ports.iter().map(port_details).collect::<Vec<_>>() }),
        ),
        Err(error) => emit_error("scan_failed", format!("串口扫描失败：{error}")),
    }
}

fn data_bits(value: u64) -> Result<DataBits, String> {
    match value {
        5 => Ok(DataBits::Five),
        6 => Ok(DataBits::Six),
        7 => Ok(DataBits::Seven),
        8 => Ok(DataBits::Eight),
        _ => Err("数据位必须为 5、6、7 或 8。".to_owned()),
    }
}

fn stop_bits(value: u64) -> Result<StopBits, String> {
    match value {
        1 => Ok(StopBits::One),
        2 => Ok(StopBits::Two),
        _ => Err("停止位必须为 1 或 2。".to_owned()),
    }
}

fn parity(value: &str) -> Result<Parity, String> {
    match value {
        "none" => Ok(Parity::None),
        "odd" => Ok(Parity::Odd),
        "even" => Ok(Parity::Even),
        _ => Err("校验仅支持 none、odd 或 even。".to_owned()),
    }
}

fn flow_control(value: &str) -> Result<FlowControl, String> {
    match value {
        "none" => Ok(FlowControl::None),
        "rts_cts" => Ok(FlowControl::Hardware),
        "xon_xoff" => Ok(FlowControl::Software),
        _ => Err("流控仅支持 none、rts_cts 或 xon_xoff。".to_owned()),
    }
}

fn payload_string(payload: &Value, key: &str) -> Result<String, String> {
    payload
        .get(key)
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("缺少或无效的 {key}。"))
}

fn payload_u64(payload: &Value, key: &str) -> Result<u64, String> {
    payload
        .get(key)
        .and_then(Value::as_u64)
        .ok_or_else(|| format!("缺少或无效的 {key}。"))
}

fn payload_hex_commands(payload: &Value) -> Result<Vec<Vec<u8>>, String> {
    let values = payload
        .get("commands")
        .and_then(Value::as_array)
        .ok_or_else(|| "缺少或无效的 commands。".to_owned())?;
    if values.is_empty() {
        return Err("周期发送至少需要一条命令。".to_owned());
    }
    values
        .iter()
        .map(|value| {
            value
                .as_str()
                .ok_or_else(|| "周期命令必须是 HEX 字符串。".to_owned())
                .and_then(parse_hex)
        })
        .collect()
}

fn write_serial_data(opened: &mut PortSession, bytes: &[u8]) -> Result<(), String> {
    opened
        .port
        .write_all(bytes)
        .map_err(|error| format!("串口写入失败：{error}"))?;
    opened
        .port
        .flush()
        .map_err(|error| format!("串口刷新失败：{error}"))?;
    emit(
        "serial_data",
        json!({"direction": "tx", "timestamp": timestamp(), "bytes": hex(bytes)}),
    );
    Ok(())
}

fn run_periodic_send(periodic: &mut Option<PeriodicSend>, session: &mut Option<PortSession>) {
    let Some(job) = periodic.as_ref() else {
        return;
    };
    let commands = job.commands.clone();
    let interval = job.interval;

    for bytes in commands {
        let Some(opened) = session.as_mut() else {
            *periodic = None;
            emit_error("periodic_stopped", "串口已关闭，周期发送已停止。");
            emit("periodic_state", json!({"active": false}));
            return;
        };
        if let Err(error) = write_serial_data(opened, &bytes) {
            *periodic = None;
            emit_error("periodic_write_failed", error);
            emit("periodic_state", json!({"active": false}));
            return;
        }
    }

    if let Some(job) = periodic.as_mut() {
        job.next_due = Instant::now() + interval;
    }
}

fn spawn_reader(
    mut port: Box<dyn SerialPort>,
    session: u64,
    stop: Arc<AtomicBool>,
    sender: SyncSender<CoreEvent>,
) -> JoinHandle<()> {
    thread::spawn(move || {
        let mut buffer = [0_u8; READ_BUFFER_BYTES];
        let mut pending = PendingRx::default();
        let mut dropped_bytes = 0_u64;

        let send_pending = |pending: &mut PendingRx, dropped_bytes: &mut u64| {
            let Some((bytes, received_at)) = pending.take() else {
                return true;
            };
            let event = CoreEvent::SerialData {
                session,
                bytes,
                timestamp: received_at,
                dropped_bytes: *dropped_bytes,
            };
            match sender.try_send(event) {
                Ok(()) => {
                    *dropped_bytes = 0;
                    true
                }
                Err(TrySendError::Full(CoreEvent::SerialData { bytes, .. })) => {
                    *dropped_bytes += bytes.len() as u64;
                    true
                }
                Err(TrySendError::Disconnected(_)) => false,
                Err(TrySendError::Full(_)) => unreachable!("reader only sends serial data"),
            }
        };

        while !stop.load(Ordering::Relaxed) {
            match port.read(&mut buffer) {
                Ok(0) => {}
                Ok(count) => {
                    pending.append(&buffer[..count], timestamp());
                    if pending.bytes.len() >= MAX_BATCH_BYTES
                        && !send_pending(&mut pending, &mut dropped_bytes)
                    {
                        break;
                    }
                }
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
                    ) =>
                {
                    if !send_pending(&mut pending, &mut dropped_bytes) {
                        break;
                    }
                }
                Err(error) => {
                    if !stop.load(Ordering::Relaxed) {
                        let _ = sender.send(CoreEvent::SerialFault {
                            session,
                            message: format!("串口读取失败：{error}"),
                        });
                    }
                    break;
                }
            }
        }
    })
}

fn close_session(session: PortSession) {
    session.stop.store(true, Ordering::Relaxed);
    drop(session.port);
    let _ = session.reader.join();
}

fn open_port(
    payload: &Value,
    session_id: u64,
    sender: SyncSender<CoreEvent>,
) -> Result<PortSession, String> {
    let port_name = payload_string(payload, "port")?;
    let baud_rate = payload_u64(payload, "baudRate")? as u32;
    let data_bits = data_bits(payload.get("dataBits").and_then(Value::as_u64).unwrap_or(8))?;
    let stop_bits = stop_bits(payload.get("stopBits").and_then(Value::as_u64).unwrap_or(1))?;
    let parity = parity(
        payload
            .get("parity")
            .and_then(Value::as_str)
            .unwrap_or("none"),
    )?;
    let flow_control = flow_control(
        payload
            .get("flowControl")
            .and_then(Value::as_str)
            .unwrap_or("none"),
    )?;

    let mut port = serialport::new(&port_name, baud_rate)
        .data_bits(data_bits)
        .stop_bits(stop_bits)
        .parity(parity)
        .flow_control(flow_control)
        .timeout(RX_IDLE_BOUNDARY)
        .open()
        .map_err(|error| format!("无法打开 {port_name}：{error}"))?;
    let reader_port = port
        .try_clone()
        .map_err(|error| format!("无法创建 {port_name} 的读取通道：{error}"))?;
    // Flush only drains outgoing bytes retained by a previous handle. It does
    // not discard incoming data, which must remain visible to the user.
    let _ = port.flush();
    let stop = Arc::new(AtomicBool::new(false));
    let reader = spawn_reader(reader_port, session_id, Arc::clone(&stop), sender);
    Ok(PortSession {
        id: session_id,
        port,
        stop,
        reader,
    })
}

fn start_command_reader(sender: SyncSender<CoreEvent>) {
    thread::spawn(move || {
        for line in io::stdin().lock().lines() {
            let command = line
                .map_err(|error| format!("读取命令失败：{error}"))
                .and_then(|line| serde_json::from_str(&line).map_err(|error| error.to_string()));
            if sender.send(CoreEvent::Command(command)).is_err() {
                return;
            }
        }
        let _ = sender.send(CoreEvent::InputClosed);
    });
}

fn main() {
    let (sender, receiver): (SyncSender<CoreEvent>, Receiver<CoreEvent>) =
        mpsc::sync_channel(MAX_EVENT_QUEUE);
    start_command_reader(sender.clone());

    emit(
        "ready",
        json!({"protocolVersion": 1, "coreVersion": "0.2.0"}),
    );
    emit_state("disconnected", None);

    let mut session: Option<PortSession> = None;
    let mut periodic: Option<PeriodicSend> = None;
    let mut next_session_id = 1_u64;
    loop {
        let wait = periodic
            .as_ref()
            .map(|job| job.next_due.saturating_duration_since(Instant::now()))
            .unwrap_or_else(|| Duration::from_millis(100));
        match receiver.recv_timeout(wait) {
            Ok(CoreEvent::Command(Err(error))) => emit_error("invalid_command", error),
            Ok(CoreEvent::Command(Ok(command))) => match command.command.as_str() {
                "hello" => {
                    emit_state(
                        if session.is_some() {
                            "connected"
                        } else {
                            "disconnected"
                        },
                        None,
                    );
                    scan_ports();
                }
                "ping" => emit("pong", json!({})),
                "scan_ports" => scan_ports(),
                "open_port" => {
                    if session.is_some() {
                        emit_error("already_connected", "已有串口处于连接状态，请先关闭它。");
                        continue;
                    }
                    let name = payload_string(&command.payload, "port")
                        .unwrap_or_else(|_| "串口".to_owned());
                    emit_state("connecting", Some(&name));
                    match open_port(&command.payload, next_session_id, sender.clone()) {
                        Ok(opened) => {
                            next_session_id += 1;
                            emit_state("connected", Some(&name));
                            session = Some(opened);
                        }
                        Err(error) => {
                            emit_error("open_failed", error);
                            emit_state("disconnected", None);
                            scan_ports();
                        }
                    }
                }
                "close_port" => {
                    periodic = None;
                    if let Some(opened) = session.take() {
                        close_session(opened);
                    }
                    emit_state("disconnected", None);
                    scan_ports();
                }
                "write_data" => {
                    let result = (|| {
                        let bytes = parse_hex(&payload_string(&command.payload, "bytes")?)?;
                        let opened = session
                            .as_mut()
                            .ok_or_else(|| "当前没有已连接的串口。".to_owned())?;
                        write_serial_data(opened, &bytes)
                    })();
                    if let Err(error) = result {
                        emit_error("write_failed", error);
                    }
                }
                "start_periodic" => {
                    let result = (|| {
                        let interval_ms = payload_u64(&command.payload, "intervalMs")?;
                        if interval_ms < 10 || interval_ms > 3_600_000 {
                            return Err("周期必须在 10–3600000 ms 之间。".to_owned());
                        }
                        if session.is_none() {
                            return Err("当前没有已连接的串口。".to_owned());
                        }
                        let commands = payload_hex_commands(&command.payload)?;
                        periodic = Some(PeriodicSend {
                            interval: Duration::from_millis(interval_ms),
                            commands,
                            next_due: Instant::now(),
                        });
                        run_periodic_send(&mut periodic, &mut session);
                        if periodic.is_some() {
                            emit("periodic_state", json!({"active": true}));
                        }
                        Ok::<(), String>(())
                    })();
                    if let Err(error) = result {
                        periodic = None;
                        emit_error("periodic_start_failed", error);
                        emit("periodic_state", json!({"active": false}));
                    }
                }
                "stop_periodic" => {
                    periodic = None;
                    emit("periodic_state", json!({"active": false}));
                }
                _ => emit_error("unsupported", "不支持的 Core 命令。"),
            },
            Ok(CoreEvent::SerialData {
                session: event_session,
                bytes,
                timestamp,
                dropped_bytes,
            }) => {
                if session
                    .as_ref()
                    .is_some_and(|opened| opened.id == event_session)
                {
                    emit(
                        "serial_data",
                        json!({"direction": "rx", "timestamp": timestamp, "bytes": hex(&bytes), "droppedBytes": dropped_bytes}),
                    );
                    if dropped_bytes > 0 {
                        emit_error(
                            "backpressure",
                            format!("UI 消费过慢，已丢弃 {dropped_bytes} 字节以保持内存有界。"),
                        );
                    }
                }
            }
            Ok(CoreEvent::SerialFault {
                session: event_session,
                message,
            }) => {
                if session
                    .as_ref()
                    .is_some_and(|opened| opened.id == event_session)
                {
                    periodic = None;
                    if let Some(opened) = session.take() {
                        close_session(opened);
                    }
                    emit_error("read_failed", message);
                    emit_state("error", None);
                    emit_state("disconnected", None);
                    scan_ports();
                }
            }
            Ok(CoreEvent::InputClosed) | Err(RecvTimeoutError::Disconnected) => break,
            Err(RecvTimeoutError::Timeout) => {}
        }
        if periodic
            .as_ref()
            .is_some_and(|job| Instant::now() >= job.next_due)
        {
            run_periodic_send(&mut periodic, &mut session);
        }
    }
    if let Some(opened) = session.take() {
        close_session(opened);
    }
}

#[cfg(test)]
mod tests {
    use super::{flow_control, parity, parse_hex, payload_hex_commands};
    use serde_json::json;
    use serialport::{FlowControl, Parity};

    #[test]
    fn parses_whitespace_or_compact_hex() {
        assert_eq!(parse_hex("AA 55\n0f").unwrap(), vec![0xAA, 0x55, 0x0F]);
        assert_eq!(parse_hex("AA55").unwrap(), vec![0xAA, 0x55]);
    }

    #[test]
    fn rejects_invalid_hex() {
        assert!(parse_hex("A").is_err());
        assert!(parse_hex("GG").is_err());
        assert!(parse_hex(" ").is_err());
    }

    #[test]
    fn parses_periodic_command_batches() {
        assert_eq!(
            payload_hex_commands(&json!({"commands": ["AA 55", "01"]})).unwrap(),
            vec![vec![0xAA, 0x55], vec![0x01]],
        );
        assert!(payload_hex_commands(&json!({"commands": []})).is_err());
    }

    #[test]
    fn maps_supported_link_settings() {
        assert_eq!(parity("odd").unwrap(), Parity::Odd);
        assert_eq!(flow_control("rts_cts").unwrap(), FlowControl::Hardware);
        assert!(parity("mark").is_err());
    }

    #[test]
    fn keeps_short_reads_together_until_the_idle_boundary() {
        let mut pending = super::PendingRx::default();
        pending.append(&[0x11; 10], "2026-09-11T10:00:00.000Z".to_owned());
        pending.append(&[0x11], "2026-09-11T10:00:00.001Z".to_owned());

        assert_eq!(
            pending.take(),
            Some((vec![0x11; 11], "2026-09-11T10:00:00.000Z".to_owned()))
        );
    }
}
