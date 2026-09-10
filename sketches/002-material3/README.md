## Variant: Material 3 (Material You) — Google 官方设计语言

### Design stance
严格遵循 Google **Material 3 (Material You)** 设计规范：Roboto 字体 + Material Symbols 图标 + M3 tonal 配色系统 + M3 标志性组件。这是 Google 官方设计语言的"原味"呈现。

### Key choices
- **字体**：Google 官方 Roboto（界面）+ Roboto Mono（HEX 数据）
- **图标**：Google 官方 **Material Symbols Rounded** 字体图标（非 emoji）
- **配色**：M3 tonal 色板 —— 主色 primary 容器色、surface container 层级色，深浅两套完整 token
- **组件（全部 M3 原版样式）**：
  - Navigation Rail（左侧协议切换 / 右侧扩展，胶囊状选中指示器）
  - Filled Button / Tonal Button / Error Button（全圆角 100px）
  - Segmented Button（顺序/循环/触发 三态切换）
  - Primary Tabs（带底部指示条 + Badge）
  - Outlined Text Field（浮动标签 + 边框）
  - Snackbar（底部提示）
  - 状态 Chip
- **主题**：深色为默认，右上角一键切换浅色（完整 M3 light scheme）
- **交互**：端口开关、协议/扩展选中、TAB 切换、发送模式切换、发送追加数据、主题切换

### 与上一版（001 Material Dark）的区别
| 维度 | 001 自绘深色 | 002 Material 3 |
|------|-------------|----------------|
| 字体 | Inter | **Roboto（Google 官方）** |
| 图标 | Emoji | **Material Symbols（Google 官方）** |
| 组件 | 自绘样式 | **M3 原版组件**（Navigation Rail/Segmented/Tabs...） |
| 配色 | 单色蓝 | **M3 tonal 色板** |
| 主题切换 | 无 | **深/浅一键切换** |

### Trade-offs
- 强项：Google 原味、组件规范、扩展性极好（Flutter 天然支持 M3，几乎可直接 1:1 落地）
- 弱项：M3 观感偏"通用/标准"，如果想有强烈品牌个性需在此之上再定制

### Best for
想用 Flutter 标准组件快速搭出规范、耐看、可长期维护界面的路线 —— 与既定技术栈（Flutter + Material）完全一致。
