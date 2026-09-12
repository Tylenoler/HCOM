# HCOM Phase 2 阶段报告

> 报告日期：2026-09-11  
> 阶段：Phase 2 — UART 通信内核  
> 当前版本：`0.0.2`  
> 状态：已完成本地实现与无硬件自动化验证；真实设备的连续运行性能仍需实机验收。

## 结论

Phase 2 已把 Phase 1 的演示端口、模拟连接和 TX 预览替换为真实 Windows COM 能力。Flutter 继续通过 stdio NDJSON 驱动 Rust Core；Core 负责端口枚举、打开/关闭、异步读取和真实写入，工作台只在收到 Core 的实际 RX/TX 事件后更新。

## 已完成内容

### 1. Rust UART Core

- 使用 `serialport` 接入 Windows COM 枚举、设置映射与打开/关闭。
- `scan_ports` 返回真实端口名、设备描述、硬件 ID 和端口类型；启动握手、关闭或读取故障后都会刷新。
- `open_port` 支持波特率、5–8 数据位、1/2 停止位、无/奇/偶校验，以及无/RTS-CTS/XON-XOFF 流控。
- 读取在独立 Rust 线程运行，写入通过 `write_data` 完成；成功写入后才生成 TX 事件。
- 连接状态完整覆盖 `connecting`、`connected`、`error`、`disconnected`；已连接时拒绝重复打开。

### 2. 吞吐量与资源边界

- RX 以 12ms 空闲边界聚合短读，单批最多 4KiB；Core 到 UI 队列固定 128 个事件，读取线程不因 Flutter 慢消费而阻塞。
- 队列饱和时丢弃新批次并在下一条可投递数据上报 `droppedBytes` 与 `backpressure` 错误；内存不会随运行时长无界增长。
- 单次 HEX 写入限制为 16KiB，输入在 Core 内部校验，不依赖 UI。
- Flutter HEX 视图最多保留 5000 条 Core 数据事件，实时日志不增加逐条入场动画。

### 3. Flutter 工作台绑定

- 端口下拉不再使用 COM3/4/5 演示数据，改为 Core 扫描结果；没有设备时展示可点击的刷新状态。
- 打开/关闭控制、连接 Chip、参数锁定、Snackbar 和发送按钮均绑定真实连接状态。
- HEX 视图初始为空；只有 Core 实际读到或写入的数据才出现 RX/TX 条目和字节计数。
- 日志按时间从上到下递增，最新数据追加在底部；Core 先聚合短读，避免同一段 RX 的末字节被单独展示为错误数据。
- 发送面板的本阶段输入限定为 HEX；支持已连接端口上的单条直接发送及固定间隔周期发送。可执行队列、循环调度、文本和条件发送仍保留给 Phase 4。

### 4. 协议与测试

- 更新 `protocol/stdio-ndjson.md`，记录 `scan_ports`、完整 `open_port` 参数、`write_data` 和有界背压契约。
- Rust 单元测试覆盖 HEX 输入（紧凑/空白字符/非法）和串口校验/流控映射。
- Flutter Widget 测试覆盖工作台渲染、端口/Dock 折叠、周期发送入口、时区、日志复制和字体配置。

## 验证记录

- `cargo fmt --check`：通过。
- `cargo test --manifest-path core/Cargo.toml`：4/4 通过，包含短读聚合回归用例。
- `flutter analyze --no-pub`：通过，无问题。
- `flutter test --no-pub`：9/9 通过。
- Core NDJSON 冒烟：当前机器枚举到 COM29 / COM30；`hello`、`ping`、扫描、无效 COM999 的失败路径均已核对。
- 实际句柄冒烟：COM29 按 115200、8-N-1、无流控成功经历 `connecting → connected → disconnected`。本检查未向端口写入任何数据。
- `flutter build windows --release --no-tree-shake-icons --no-pub`：通过；Release 中包含完整的 Flutter Material Icons 字体，避免增量裁剪缓存导致图标空白。
- Release 启动：`hcom.exe` 和其子进程 `hcom-core.exe` 已从标准 Release 目录启动并保持响应。当前自动化环境没有暴露原生桌面窗口，因而未取得应用截图；这项启动检查不等同于视觉验收。

## 明确边界

本阶段交付的是真实 UART 通信内核，以及单条 HEX 的直接/固定周期发送；不包含协议自动分帧、CRC/校验、字段解析、可执行发送队列、文本编码发送、循环调度、条件发送或插件系统。产品说明书中的 Mark / Space 校验尚未纳入当前 `serialport` 设置映射，需作为后续的 Windows DCB 兼容性补齐项；不能误称为已支持。没有连接可访问的物理或虚拟 COM 对时，自动化检查也不能替代实际设备收发、拔插和 8 小时连续运行验收。

## 建议的实机验收

1. 连接已知 USB-UART 或虚拟 COM 对，核对端口描述/硬件 ID、115200 8-N-1 打开与关闭。
2. 双向发送 `AA 55 01 00`，核对 TX/RX HEX、字节计数和时间戳。
3. 拔出设备，核对 `error` → `disconnected`、端口列表刷新与参数解锁。
4. 在目标波特率连续运行，记录丢包和 `backpressure`，再为容量策略确定实测阈值。
