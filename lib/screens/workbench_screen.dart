import 'dart:async';

import 'package:flutter/material.dart';

import '../app_info.dart';
import '../core/backend_bridge.dart';
import '../models/serial_entry.dart';
import '../theme/hcom_theme.dart';

enum SendMode { sequence, loop, trigger }

const _demoPorts = [
  _SerialPort(
    port: 'COM3',
    description: 'USB-SERIAL CH340',
    hardwareId: r'USB\VID_1A86&PID_7523',
    icon: Icons.usb_rounded,
  ),
  _SerialPort(
    port: 'COM4',
    description: 'Standard Serial over Bluetooth link',
    hardwareId: r'BTHENUM\{00001101-0000-1000-8000-00805F9B34FB}',
    icon: Icons.bluetooth_rounded,
  ),
  _SerialPort(
    port: 'COM5',
    description: 'USB Serial Device',
    hardwareId: r'USB\VID_0403&PID_6001',
    icon: Icons.usb_rounded,
  ),
];

class WorkbenchScreen extends StatefulWidget {
  const WorkbenchScreen(
      {super.key, required this.isDark, required this.onThemeChanged});

  final bool isDark;
  final VoidCallback onThemeChanged;

  @override
  State<WorkbenchScreen> createState() => _WorkbenchScreenState();
}

class _WorkbenchScreenState extends State<WorkbenchScreen>
    with TickerProviderStateMixin {
  final _bridge = BackendBridge();
  final _commandController = TextEditingController();
  late final StreamSubscription<Map<String, dynamic>> _eventSubscription;
  late final AnimationController _connectionPulseController;
  late final AnimationController _sendPanelFadeController;
  late List<SerialEntry> _entries;
  SendMode _sendMode = SendMode.sequence;
  bool _connected = false;
  bool _sendPanelExpanded = true;
  _SerialPort _selectedPort = _demoPorts.first;
  String _baudRate = '115200';
  String _dataBits = '8';
  String _stopBits = '1';
  String _parity = '无 None';
  String _flowControl = '无';
  int _leftRailIndex = 0;
  int _rightRailIndex = 0;
  int _selectedTab = 0;

  @override
  void initState() {
    super.initState();
    _entries = _sampleEntries();
    _connectionPulseController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 200));
    _sendPanelFadeController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 200), value: 1);
    _eventSubscription = _bridge.events.listen(_consumeCoreEvent);
    unawaited(_bridge.start());
  }

  @override
  void dispose() {
    _eventSubscription.cancel();
    _connectionPulseController.dispose();
    _sendPanelFadeController.dispose();
    _commandController.dispose();
    unawaited(_bridge.dispose());
    super.dispose();
  }

  void _consumeCoreEvent(Map<String, dynamic> event) {
    if (event['event'] != 'serial_data') return;
    final payload = event['payload'];
    if (payload is! Map) return;
    final bytes = payload['bytes'];
    if (bytes is! String) return;
    setState(() {
      _entries.insert(
        0,
        SerialEntry(
          direction: payload['direction'] == 'tx'
              ? SerialDirection.tx
              : SerialDirection.rx,
          timestamp:
              DateTime.tryParse(payload['timestamp']?.toString() ?? '') ??
                  DateTime.now(),
          hex: bytes,
          label: 'Core',
        ),
      );
      if (_entries.length > 5000) _entries.removeLast();
    });
  }

  void _showMessage(String message) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(message)));

  void _toggleConnection() {
    setState(() => _connected = !_connected);
    if (_connected) _connectionPulseController.forward(from: 0);
    _showMessage(_connected ? '已打开端口（Phase 1 界面状态）' : '端口已关闭');
  }

  void _toggleSendPanel() {
    setState(() => _sendPanelExpanded = !_sendPanelExpanded);
    _sendPanelExpanded
        ? _sendPanelFadeController.forward()
        : _sendPanelFadeController.reverse();
  }

  void _queueCommand() {
    if (_commandController.text.trim().isEmpty) return;
    _showMessage('已加入队列（队列执行将在 Phase 4 接入）');
    _commandController.clear();
  }

  void _sendMock() {
    final value = _commandController.text.trim().isEmpty
        ? 'AA 55 A0 00 00 00 00 00 00 00 00 00'
        : _commandController.text.trim().toUpperCase();
    setState(() => _entries.insert(
          0,
          SerialEntry(
              direction: SerialDirection.tx,
              timestamp: DateTime.now(),
              hex: value,
              label: '发送预览'),
        ));
    _showMessage('已写入 TX 预览；实际串口发送属于 Phase 2/4');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 64,
        titleSpacing: 16,
        title: Row(children: [
          SizedBox(
            width: 36,
            height: 36,
            child: Image.asset('Image/LOGO.png', fit: BoxFit.contain),
          ),
          const SizedBox(width: 12),
          const Text('HCOM 调试助手'),
        ]),
        actions: [
          _appAction(Icons.folder_open_rounded, '打开日志'),
          _appAction(Icons.save_rounded, '保存日志'),
          _appAction(Icons.upload_file_rounded, '导入帧配置'),
          _appAction(Icons.download_rounded, '导出帧配置'),
          _appAction(Icons.delete_sweep_rounded, '清除日志',
              () => setState(_entries.clear)),
          const Spacer(),
          _connectionChip(scheme),
          const SizedBox(width: 4),
          IconButton(
            tooltip: '切换${widget.isDark ? '浅色' : '深色'}主题',
            onPressed: widget.onThemeChanged,
            icon: Icon(widget.isDark
                ? Icons.light_mode_outlined
                : Icons.dark_mode_outlined),
          ),
          _appAction(Icons.settings_outlined, '设置'),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: Row(children: [
            _protocolRail(scheme),
            Expanded(child: _workspace(scheme)),
            _extensionRail(scheme),
          ]),
        ),
        _statusBar(scheme),
      ]),
    );
  }

  /// Leaves a deliberate M3 gap between independent toolbar actions so their
  /// circular containers do not visually merge into one control.
  Widget _appAction(IconData icon, String tooltip, [VoidCallback? action]) =>
      Padding(
        padding: const EdgeInsets.only(right: 8),
        child: IconButton.filledTonal(
          tooltip: tooltip,
          onPressed: action ?? () => _showMessage('$tooltip将在后续阶段接入'),
          icon: Icon(icon, size: 20),
        ),
      );

  Widget _connectionChip(ColorScheme scheme) {
    final accent = widget.isDark ? HcomTheme.txDark : HcomTheme.txLight;
    return ScaleTransition(
      scale: TweenSequence<double>([
        TweenSequenceItem(tween: Tween(begin: 1, end: 1.055), weight: 55),
        TweenSequenceItem(tween: Tween(begin: 1.055, end: 1), weight: 45),
      ]).animate(CurvedAnimation(
          parent: _connectionPulseController,
          curve: Easing.emphasizedDecelerate)),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Easing.standard,
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color:
              _connected ? accent.withValues(alpha: .15) : Colors.transparent,
          border: Border.all(
              color: _connected
                  ? accent.withValues(alpha: .55)
                  : scheme.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            switchInCurve: Easing.standard,
            child: Icon(
                _connected ? Icons.link_rounded : Icons.link_off_rounded,
                key: ValueKey(_connected),
                size: 16,
                color: _connected ? accent : scheme.onSurfaceVariant),
          ),
          const SizedBox(width: 8),
          Text(
              _connected
                  ? '${_selectedPort.port} · $_baudRate · $_dataBits-$_parityCode-$_stopBits'
                  : '未连接',
              style: const TextStyle(fontFamily: 'Roboto Mono', fontSize: 12)),
        ]),
      ),
    );
  }

  Widget _protocolRail(ColorScheme scheme) => _AnimatedRail(
        destinations: const [
          _RailDestination(Icons.usb_rounded, 'UART'),
          _RailDestination(Icons.route_rounded, 'CAN'),
          _RailDestination(Icons.bolt_rounded, 'CAN-FD'),
          _RailDestination(Icons.hub_rounded, 'I2C'),
          _RailDestination(Icons.lan_rounded, 'TCP'),
          _RailDestination(Icons.memory_rounded, '虚拟串口'),
          _RailDestination(Icons.settings_outlined, '设置'),
        ],
        selectedIndex: _leftRailIndex,
        onSelected: (value) {
          if (value != 0) _showMessage('仅 UART/COM 在 v1 范围内');
          setState(() => _leftRailIndex = value);
        },
        scheme: scheme,
      );

  Widget _extensionRail(ColorScheme scheme) => _AnimatedRail(
        destinations: const [
          _RailDestination(Icons.calculate_rounded, 'CRC'),
          _RailDestination(Icons.visibility_rounded, '帧监听'),
          _RailDestination(Icons.show_chart_rounded, '时序'),
          _RailDestination(Icons.science_outlined, '信号'),
          _RailDestination(Icons.link_rounded, '抓包'),
          _RailDestination(Icons.extension_rounded, '插件'),
        ],
        selectedIndex: _rightRailIndex,
        onSelected: (value) => setState(() => _rightRailIndex = value),
        scheme: scheme,
      );

  Widget _workspace(ColorScheme scheme) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _portConfiguration(scheme),
          const SizedBox(height: 14),
          _AnimatedTabStrip(
            selectedIndex: _selectedTab,
            frameCount: _entries.length,
            scheme: scheme,
            onSelected: (value) => setState(() => _selectedTab = value),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              switchInCurve: Easing.standard,
              switchOutCurve: Easing.standard,
              child: KeyedSubtree(
                key: ValueKey(_selectedTab),
                child: [
                  _hexStream(scheme),
                  _emptyPanel(Icons.data_object_rounded, '字段解析将在 Phase 3 接入'),
                  _emptyPanel(Icons.timeline_rounded, '时间轴将在 Phase 6 接入'),
                  _statistics(scheme)
                ][_selectedTab],
              ),
            ),
          ),
          const SizedBox(height: 14),
          _sendPanel(scheme, compact: MediaQuery.sizeOf(context).height < 700),
        ]),
      );

  Widget _portConfiguration(ColorScheme scheme) => LayoutBuilder(
        builder: (context, constraints) {
          final portWidth = constraints.maxWidth >= 1100
              ? 300.0
              : constraints.maxWidth >= 760
                  ? 250.0
                  : 220.0;
          final showIdentity = MediaQuery.sizeOf(context).height >= 700;
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _portField(portWidth),
                    if (showIdentity) _deviceIdentity(portWidth, scheme),
                    _selectField(
                        '波特率',
                        _baudRate,
                        const ['9600', '38400', '57600', '115200', '921600'],
                        (value) => setState(() => _baudRate = value)),
                    _selectField('数据位', _dataBits, const ['5', '6', '7', '8'],
                        (value) => setState(() => _dataBits = value)),
                    _selectField('停止位', _stopBits, const ['1', '2'],
                        (value) => setState(() => _stopBits = value)),
                    _selectField(
                        '校验',
                        _parity,
                        const ['无 None', '奇 Odd', '偶 Even'],
                        (value) => setState(() => _parity = value)),
                    _selectField(
                        '流控',
                        _flowControl,
                        const ['无', 'RTS/CTS', 'XON/XOFF'],
                        (value) => setState(() => _flowControl = value)),
                    FilledButton.icon(
                      style: _connected
                          ? FilledButton.styleFrom(
                              backgroundColor: scheme.error,
                              foregroundColor: scheme.onError)
                          : null,
                      onPressed: _toggleConnection,
                      icon: Icon(_connected
                          ? Icons.link_off_rounded
                          : Icons.link_rounded),
                      label: Text(_connected ? '关闭端口' : '打开端口'),
                    ),
                  ]),
            ),
          );
        },
      );

  Widget _portField(double width) => SizedBox(
        width: width,
        child: _HcomPopupField<_SerialPort>(
          width: width,
          label: '串口',
          value: _selectedPort,
          options: _demoPorts,
          textOf: (port) => '${port.port} · ${port.description}',
          iconOf: (port) => port.icon,
          onChanged: _connected
              ? null
              : (port) => setState(() => _selectedPort = port),
        ),
      );

  Widget _deviceIdentity(double width, ColorScheme scheme) => SizedBox(
        width: width,
        child: Tooltip(
          message: '硬件 ID: ${_selectedPort.hardwareId}',
          child: Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
                border: Border.all(color: scheme.outlineVariant),
                borderRadius: BorderRadius.circular(8)),
            child: Row(children: [
              Icon(_selectedPort.icon, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                  child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(_selectedPort.description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w500)),
                    Text(_selectedPort.hardwareId,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontFamily: 'Roboto Mono',
                            fontSize: 11)),
                  ])),
            ]),
          ),
        ),
      );

  String get _parityCode => switch (_parity) {
        '奇 Odd' => 'O',
        '偶 Even' => 'E',
        _ => 'N',
      };

  Widget _selectField(String label, String selected, List<String> options,
          ValueChanged<String> onChanged) =>
      SizedBox(
        width: 132,
        child: _HcomPopupField<String>(
          width: 132,
          label: label,
          value: selected,
          options: options,
          textOf: (option) => option,
          useMono: true,
          onChanged: _connected ? null : onChanged,
        ),
      );

  Widget _hexStream(ColorScheme scheme) => Container(
        decoration: BoxDecoration(
            color: scheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(16)),
        child: ListView.builder(
          padding: const EdgeInsets.all(8),
          itemCount: _entries.length,
          itemBuilder: (_, index) => _entryRow(_entries[index], scheme, index),
        ),
      );

  Widget _entryRow(SerialEntry entry, ColorScheme scheme, int index) {
    final isRx = entry.direction == SerialDirection.rx;
    final accent = isRx
        ? (widget.isDark ? HcomTheme.rxDark : HcomTheme.rxLight)
        : (widget.isDark ? HcomTheme.txDark : HcomTheme.txLight);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {},
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(children: [
              Container(
                  width: 42,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                      color: accent.withValues(alpha: .20),
                      borderRadius: BorderRadius.circular(99)),
                  child: Text(isRx ? 'RX' : 'TX',
                      style: TextStyle(
                          color: accent,
                          fontWeight: FontWeight.w700,
                          fontSize: 11))),
              const SizedBox(width: 12),
              SizedBox(
                  width: 92,
                  child: Text(_formatTime(entry.timestamp),
                      style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 11.5,
                          fontFamily: 'Roboto Mono'))),
              const SizedBox(width: 12),
              Expanded(
                  child: Text(entry.hex,
                      style: TextStyle(
                          color: scheme.onSurface,
                          fontFamily: 'Roboto Mono',
                          fontSize: 12.5))),
              const SizedBox(width: 12),
              Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                      color: scheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(8)),
                  child: Text(
                      entry.label == '帧'
                          ? '帧 #${_entries.length - index}'
                          : entry.label,
                      style: TextStyle(
                          fontSize: 11, color: scheme.onSurfaceVariant))),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _emptyPanel(IconData icon, String text) => Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 44),
        const SizedBox(height: 12),
        Text(text)
      ]));

  Widget _statistics(ColorScheme scheme) => Center(
        child: Wrap(
            spacing: 12,
            runSpacing: 12,
            alignment: WrapAlignment.center,
            children: [
              _statCard(
                  'RX',
                  '${_entries.where((entry) => entry.direction == SerialDirection.rx).fold(0, (sum, entry) => sum + entry.byteCount)} B',
                  HcomTheme.rxDark,
                  scheme),
              _statCard(
                  'TX',
                  '${_entries.where((entry) => entry.direction == SerialDirection.tx).fold(0, (sum, entry) => sum + entry.byteCount)} B',
                  HcomTheme.txDark,
                  scheme),
              _statCard('帧', '${_entries.length}', scheme.primary, scheme),
            ]),
      );

  Widget _statCard(
          String label, String value, Color color, ColorScheme scheme) =>
      Card(
          child: SizedBox(
              width: 160,
              height: 110,
              child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label, style: TextStyle(color: color)),
                        const Spacer(),
                        Text(value,
                            style: TextStyle(
                                fontSize: 22,
                                color: scheme.onSurface,
                                fontFamily: 'Roboto Mono'))
                      ]))));

  Widget _sendPanel(ColorScheme scheme, {required bool compact}) => Card(
        margin: EdgeInsets.zero,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const Text('发送面板',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
              const Spacer(),
              SegmentedButton<SendMode>(
                segments: const [
                  ButtonSegment(
                      value: SendMode.sequence,
                      icon: Icon(Icons.playlist_play_rounded, size: 17),
                      label: Text('顺序')),
                  ButtonSegment(
                      value: SendMode.loop,
                      icon: Icon(Icons.repeat_rounded, size: 17),
                      label: Text('循环')),
                  ButtonSegment(
                      value: SendMode.trigger,
                      icon: Icon(Icons.bolt_rounded, size: 17),
                      label: Text('触发'))
                ],
                selected: {_sendMode},
                onSelectionChanged: (value) =>
                    setState(() => _sendMode = value.first),
              ),
              IconButton(
                tooltip: _sendPanelExpanded ? '收起发送面板' : '展开发送面板',
                onPressed: _toggleSendPanel,
                icon: Icon(_sendPanelExpanded
                    ? Icons.keyboard_arrow_down_rounded
                    : Icons.keyboard_arrow_up_rounded),
              ),
            ]),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Easing.standard,
              child: Align(
                alignment: Alignment.topCenter,
                heightFactor: _sendPanelExpanded ? 1 : 0,
                child: FadeTransition(
                  opacity: CurvedAnimation(
                      parent: _sendPanelFadeController, curve: Easing.standard),
                  child: Column(children: [
                    if (!compact) ...[
                      const SizedBox(height: 8),
                      _queueRow('AA 55 A0 00 00 00 00 00 00 00 00 00',
                          '间隔 200ms\n心跳', scheme),
                      const SizedBox(height: 6),
                      _queueRow(
                          'AA 55 01 01 04 00 41 42 20 1A', '立即\n查询状态', scheme),
                    ],
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(
                          child: TextField(
                              controller: _commandController,
                              decoration: const InputDecoration(
                                  hintText:
                                      '输入 HEX 或文本命令，例如 AA 55 01 01 04 00 41 42 20 1A',
                                  isDense: true))),
                      const SizedBox(width: 10),
                      FilledButton.tonalIcon(
                          onPressed: _queueCommand,
                          icon: const Icon(Icons.add_rounded),
                          label: const Text('队列')),
                      const SizedBox(width: 10),
                      FilledButton.icon(
                          onPressed: _sendMock,
                          icon: const Icon(Icons.send_rounded),
                          label: const Text('发送')),
                    ]),
                  ]),
                ),
              ),
            ),
          ]),
        ),
      );

  Widget _queueRow(String hex, String meta, ColorScheme scheme) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
            color: scheme.surfaceContainerLowest,
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(12)),
        child: Row(children: [
          Expanded(
              child: Text(hex,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontFamily: 'Roboto Mono', fontSize: 12.5))),
          Text(meta,
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          IconButton(
              iconSize: 18,
              onPressed: () {},
              icon: const Icon(Icons.arrow_upward_rounded)),
          IconButton(
              iconSize: 18,
              onPressed: () {},
              icon: const Icon(Icons.arrow_downward_rounded)),
          IconButton(
              iconSize: 18,
              onPressed: () => _showMessage('队列编辑将在 Phase 4 接入'),
              icon: const Icon(Icons.close_rounded))
        ]),
      );

  Widget _statusBar(ColorScheme scheme) {
    final rx = _entries
        .where((entry) => entry.direction == SerialDirection.rx)
        .fold(0, (sum, entry) => sum + entry.byteCount);
    final tx = _entries
        .where((entry) => entry.direction == SerialDirection.tx)
        .fold(0, (sum, entry) => sum + entry.byteCount);
    Text item(String label, String value) => Text.rich(
          TextSpan(
            text: '$label ',
            children: [
              TextSpan(
                text: value,
                style: TextStyle(
                    color: scheme.onSurface,
                    fontFamily: 'Roboto Mono',
                    fontWeight: FontWeight.w500),
              ),
            ],
          ),
          style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
        );
    return Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        color: scheme.surfaceContainerLow,
        child: Row(children: [
          item('RX', '$rx B'),
          const SizedBox(width: 20),
          item('TX', '$tx B'),
          const SizedBox(width: 20),
          item('速率', '—'),
          const Spacer(),
          item('帧', '${_entries.length}'),
          const SizedBox(width: 20),
          item('校验通过率', '—'),
          const SizedBox(width: 20),
          item('版本', applicationVersion),
        ]));
  }

  String _formatTime(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}:${value.second.toString().padLeft(2, '0')}.${value.millisecond.toString().padLeft(3, '0')}';

  List<SerialEntry> _sampleEntries() {
    final now = DateTime.now();
    return [
      SerialEntry(
          direction: SerialDirection.rx,
          timestamp: now.subtract(const Duration(milliseconds: 920)),
          hex: 'AA 55 01 00 0B 1C 02 34 56 78 9A BC 1C',
          label: '帧'),
      SerialEntry(
          direction: SerialDirection.tx,
          timestamp: now.subtract(const Duration(milliseconds: 700)),
          hex: 'AA 55 A0 00 00 00 00 00 00 00 00 00',
          label: '心跳'),
      SerialEntry(
          direction: SerialDirection.rx,
          timestamp: now.subtract(const Duration(milliseconds: 620)),
          hex: 'AA 55 01 01 04 00 41 42 20 1A',
          label: '帧'),
      SerialEntry(
          direction: SerialDirection.rx,
          timestamp: now.subtract(const Duration(milliseconds: 400)),
          hex: 'AA 55 01 02 08 00 FF 00 01 02 03 04 9C 2F',
          label: '帧'),
      SerialEntry(
          direction: SerialDirection.rx,
          timestamp: now.subtract(const Duration(milliseconds: 180)),
          hex: 'AA 55 01 03 02 00 7F D2 09',
          label: '帧'),
    ];
  }
}

/// A zero-padding M3 popup menu. Flutter's legacy dropdown menu has fixed
/// vertical list padding, which leaves a visible gap above a selected first
/// item. This component keeps the selection fill edge-to-edge and clips it to
/// the same 16px radius as the menu surface.
class _HcomPopupField<T> extends StatelessWidget {
  const _HcomPopupField({
    required this.width,
    required this.label,
    required this.value,
    required this.options,
    required this.textOf,
    required this.onChanged,
    this.iconOf,
    this.useMono = false,
  });

  final double width;
  final String label;
  final T value;
  final List<T> options;
  final String Function(T value) textOf;
  final IconData? Function(T value)? iconOf;
  final ValueChanged<T>? onChanged;
  final bool useMono;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onChanged != null;
    final textStyle = TextStyle(
      color: enabled ? scheme.onSurface : scheme.onSurfaceVariant,
      fontFamily: useMono ? 'Roboto Mono' : null,
      fontSize: 13,
    );
    return PopupMenuButton<T>(
      tooltip: '',
      enabled: enabled,
      padding: EdgeInsets.zero,
      menuPadding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      offset: const Offset(0, 4),
      constraints: BoxConstraints(minWidth: width, maxWidth: width),
      color: scheme.surfaceContainerLowest,
      elevation: 4,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      onSelected: onChanged,
      itemBuilder: (context) => options
          .map((option) => PopupMenuItem<T>(
                value: option,
                height: 48,
                padding: EdgeInsets.zero,
                child: Container(
                  width: double.infinity,
                  height: 48,
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  color: option == value
                      ? scheme.secondaryContainer
                      : Colors.transparent,
                  child: Row(children: [
                    if (iconOf?.call(option) case final icon?) ...[
                      Icon(icon, size: 18, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                        child: Text(textOf(option),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textStyle)),
                  ]),
                ),
              ))
          .toList(),
      child: InputDecorator(
        isEmpty: false,
        decoration: InputDecoration(labelText: label, isDense: true),
        child: Row(children: [
          Expanded(
              child: Text(textOf(value),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textStyle)),
          Icon(Icons.arrow_drop_down_rounded,
              color: enabled ? scheme.onSurfaceVariant : scheme.outline),
        ]),
      ),
    );
  }
}

class _SerialPort {
  const _SerialPort({
    required this.port,
    required this.description,
    required this.hardwareId,
    required this.icon,
  });

  final String port;
  final String description;
  final String hardwareId;
  final IconData icon;
}

class _RailDestination {
  const _RailDestination(this.icon, this.label);

  final IconData icon;
  final String label;
}

/// M3 rail with an explicitly timed, shared selection pill.
class _AnimatedRail extends StatelessWidget {
  const _AnimatedRail({
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
    required this.scheme,
  });

  final List<_RailDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final ColorScheme scheme;

  static const _itemHeight = 66.0;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 88,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
          child: Material(
            color: scheme.surfaceContainerLow,
            elevation: 1,
            shadowColor: Colors.black.withValues(alpha: .18),
            shape: const StadiumBorder(),
            clipBehavior: Clip.antiAlias,
            child: Stack(children: [
              AnimatedPositioned(
                duration: const Duration(milliseconds: 250),
                curve: Easing.emphasizedDecelerate,
                left: 4,
                right: 4,
                top: 4 + selectedIndex * _itemHeight,
                height: 58,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                        color: scheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(100)),
                  ),
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(destinations.length, (index) {
                  final destination = destinations[index];
                  final selected = index == selectedIndex;
                  return SizedBox(
                    height: _itemHeight,
                    width: double.infinity,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(100),
                      onTap: () => onSelected(index),
                      child: Column(
                          mainAxisAlignment: MainAxisAlignment.start,
                          children: [
                            const SizedBox(height: 14),
                            Icon(destination.icon,
                                size: 20,
                                color: selected
                                    ? scheme.onSecondaryContainer
                                    : scheme.onSurfaceVariant),
                            const SizedBox(height: 3),
                            Text(destination.label,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                    color: selected
                                        ? scheme.onSurface
                                        : scheme.onSurfaceVariant)),
                          ]),
                    ),
                  );
                }),
              ),
            ]),
          ),
        ),
      );
}

/// Four equal M3 primary tabs with a 200ms standard-motion indicator.
class _AnimatedTabStrip extends StatelessWidget {
  const _AnimatedTabStrip({
    required this.selectedIndex,
    required this.frameCount,
    required this.scheme,
    required this.onSelected,
  });

  final int selectedIndex;
  final int frameCount;
  final ColorScheme scheme;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    const labels = ['HEX 原始', '字段解析', '时间轴', '统计'];
    return SizedBox(
      height: 48,
      child: LayoutBuilder(builder: (context, constraints) {
        final tabWidth = constraints.maxWidth / labels.length;
        return Stack(children: [
          Positioned.fill(
            child: Row(
              children: List.generate(labels.length, (index) {
                final selected = index == selectedIndex;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Material(
                      color: selected
                          ? scheme.surfaceContainerHighest
                          : scheme.surfaceContainerLow,
                      shape: const RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.vertical(top: Radius.circular(12))),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => onSelected(index),
                        child: Center(
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Text(labels[index],
                                style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: selected
                                        ? scheme.primary
                                        : scheme.onSurfaceVariant)),
                            if (index == 0) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 7, vertical: 1),
                                decoration: BoxDecoration(
                                    color: scheme.primaryContainer,
                                    borderRadius: BorderRadius.circular(8)),
                                child: Text('$frameCount',
                                    style: TextStyle(
                                        color: scheme.onPrimaryContainer,
                                        fontSize: 11,
                                        fontFamily: 'Roboto Mono')),
                              ),
                            ],
                          ]),
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
          Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Divider(height: 1, color: scheme.outlineVariant)),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 200),
            curve: Easing.standard,
            left: selectedIndex * tabWidth + (tabWidth - 48) / 2,
            bottom: 0,
            width: 48,
            height: 3,
            child: DecoratedBox(
                decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(8)))),
          ),
        ]);
      }),
    );
  }
}
