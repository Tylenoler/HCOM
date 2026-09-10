# HCOM — 串口调试助手

> 一个以 **UART 串口通信 + 用户自定义协议帧解析** 为核心的桌面端工程调试工具。
> 插件化架构 · 性能优先 · Material 3 设计 · 面向嵌入式工程师 · 自用与开源同步。

---

## 📖 先读这里

| 文档 | 说明 |
|------|------|
| **[交接说明.md](交接说明.md)** | ⭐ **从这里开始** —— 项目全貌、已冻结决策、当前进度、下一步、接手须知 |
| [产品说明书.md](产品说明书.md) | 产品完整定义：功能 / 架构 / 交互 / 边界 / 里程碑 |
| [设计规范.md](设计规范.md) | 设计系统：Material 3 token / 字体 / 组件 / 布局 / Flutter 对照表 |

## 🎨 UI 原型（可直接打开）

- ✅ **[sketches/002-material3/index.html](sketches/002-material3/index.html)** —— 已采纳的设计基准（Material 3，可交互，深/浅主题切换）
- 🗄️ [sketches/001-material-dark/index.html](sketches/001-material-dark/index.html) —— 早期版本，仅存档

> 查看方式：浏览器直接打开 HTML 文件，无需构建、无依赖。

## 🧭 项目速览

| 维度 | 决策 |
|------|------|
| 核心能力 | 双向 UART 收发 + 用户自定义协议帧解析 |
| UI 前端 | Flutter（Google **Material 3**） |
| 后端 | Rust（串口 + 协议分析，性能优先） |
| 插件体系 | 双轨：普通 Python / 高性能 Rust |
| 目标平台 | Windows 桌面端为主 |
| 通信类型（v1） | 仅 UART / COM |

## 📌 两条底线

1. **写速快** —— 决定能否自用与开源同步推进
2. **不能一卡一卡** —— 调试工具，性能是生命线

## 🔗 相关

- 仓库：`https://github.com/Tylenoler/HCOM`

---

*本项目遵循 project-lifecycle 文档规范（说明书 / 日志 / 结果）。*
