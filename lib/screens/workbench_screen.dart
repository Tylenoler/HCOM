import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_info.dart';
import '../core/backend_bridge.dart';
import '../models/log_copy.dart';
import '../models/serial_entry.dart';
import '../models/time_zone.dart';
import '../theme/hcom_theme.dart';

enum SendMode { sequence, loop, trigger, periodic }

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
  final _periodicIntervalController = TextEditingController(text: '1000');
  final _streamController = ScrollController();
  late final StreamSubscription<Map<String, dynamic>> _eventSubscription;
  late final AnimationController _connectionPulseController;
  late final AnimationController _sendPanelFadeController;
  late List<SerialEntry> _entries;
  List<_SerialPort> _ports = const [];
  SendMode _sendMode = SendMode.sequence;
  bool _connected = false;
  bool _connecting = false;
  bool _portConfigurationExpanded = true;
  bool _sendPanelExpanded = true;
  bool _periodicSending = false;
  Timer? _periodicSendTimer;
  Timer? _notificationTimer;
  String? _notificationMessage;
  bool _notificationHovered = false;
  String? _selectedLogText;
  bool _showLineNumbers = false;
  int _timeZoneOffsetMinutes = defaultTimeZoneOffsetMinutes;
  _SerialPort? _selectedPort;
  String _baudRate = '115200';
  String _dataBits = '8';
  String _stopBits = '1';
  String _parity = '无 None';
  String _flowControl = '无';
  int _leftRailIndex = 0;
  int _rightRailIndex = 0;
  bool _leftRailExpanded = true;
  bool _rightRailExpanded = true;
  int _selectedTab = 0;

  @override
  void initState() {
    super.initState();
    _entries = [];
    _connectionPulseController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 200));
    _sendPanelFadeController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 200), value: 1);
    _eventSubscription = _bridge.events.listen(_consumeCoreEvent);
    unawaited(_bridge.start());
    unawaited(_loadTimeZone());
  }

  @override
  void dispose() {
    _periodicSendTimer?.cancel();
    _notificationTimer?.cancel();
    _eventSubscription.cancel();
    _connectionPulseController.dispose();
    _sendPanelFadeController.dispose();
    _commandController.dispose();
    _periodicIntervalController.dispose();
    _streamController.dispose();
    unawaited(_bridge.dispose());
    super.dispose();
  }

  void _consumeCoreEvent(Map<String, dynamic> event) {
    final payload = event['payload'];
    if (payload is! Map) return;
    switch (event['event']) {
      case 'ports':
        final rawPorts = payload['ports'];
        if (rawPorts is! List) return;
        final ports = rawPorts
            .whereType<Map>()
            .map(_SerialPort.fromCore)
            .whereType<_SerialPort>()
            .toList();
        final retained =
            ports.where((port) => port.port == _selectedPort?.port);
        setState(() {
          _ports = ports;
          _selectedPort = retained.isNotEmpty
              ? retained.first
              : (ports.isEmpty ? null : ports.first);
        });
      case 'connection_state':
        final state = payload['state'];
        if (state is! String) return;
        final wasConnected = _connected;
        setState(() {
          _connecting = state == 'connecting';
          _connected = state == 'connected';
        });
        if (!_connected && wasConnected) _stopPeriodicSend();
        if (_connected && !wasConnected) {
          _connectionPulseController.forward(from: 0);
          _showMessage('已连接 ${payload['port'] ?? _selectedPort?.port ?? '串口'}');
        }
      case 'serial_data':
        final bytes = payload['bytes'];
        if (bytes is! String) return;
        final followLatest = !_streamController.hasClients ||
            _streamController.position.maxScrollExtent -
                    _streamController.position.pixels <
                48;
        setState(() {
          _entries.add(
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
          if (_entries.length > 5000) _entries.removeAt(0);
        });
        if (followLatest) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_streamController.hasClients) {
              _streamController.jumpTo(
                _streamController.position.maxScrollExtent,
              );
            }
          });
        }
      case 'error':
        final message = payload['message'];
        if (message is String && message.isNotEmpty) _showMessage(message);
    }
  }

  void _showMessage(String message) {
    _notificationTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _notificationMessage = message;
      _notificationHovered = false;
    });
    _notificationTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _notificationMessage = null);
    });
  }

  Future<void> _loadTimeZone() async {
    final preferences = await SharedPreferences.getInstance();
    final offset = preferences.getInt('displayTimeZoneOffsetMinutes');
    if (!mounted ||
        offset == null ||
        !availableTimeZoneOffsets.contains(offset)) {
      return;
    }
    setState(() => _timeZoneOffsetMinutes = offset);
  }

  Future<void> _showSettings() async {
    final selectedOffset = await showDialog<int>(
      context: context,
      builder: (context) {
        var draftOffset = _timeZoneOffsetMinutes;
        return StatefulBuilder(builder: (context, setDialogState) {
          return AlertDialog(
            title: const Text('设置'),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.schedule_rounded),
                title: const Text('日志时间时区'),
                subtitle: Text(timeZoneLabel(draftOffset)),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  onPressed: () async {
                    final offset = await _chooseTimeZone(context, draftOffset);
                    if (offset != null) {
                      setDialogState(() => draftOffset = offset);
                    }
                  },
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('修改时区'),
                ),
              ),
            ]),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消')),
              FilledButton(
                  onPressed: () => Navigator.pop(context, draftOffset),
                  child: const Text('保存')),
            ],
          );
        });
      },
    );
    if (selectedOffset == null || selectedOffset == _timeZoneOffsetMinutes) {
      return;
    }
    setState(() => _timeZoneOffsetMinutes = selectedOffset);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt('displayTimeZoneOffsetMinutes', selectedOffset);
    if (mounted) _showMessage('日志时间已切换为 ${timeZoneLabel(selectedOffset)}');
  }

  Future<int?> _chooseTimeZone(BuildContext context, int selectedOffset) =>
      showDialog<int>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('选择时区'),
          content: SizedBox(
            width: 360,
            height: 420,
            child: ListView(
              children: availableTimeZoneOffsets
                  .map((offset) => ListTile(
                        dense: true,
                        leading: Icon(offset == selectedOffset
                            ? Icons.check_rounded
                            : Icons.schedule_outlined),
                        title: Text(timeZoneLabel(offset)),
                        onTap: () => Navigator.pop(context, offset),
                      ))
                  .toList(),
            ),
          ),
        ),
      );

  void _toggleConnection() {
    if (_connected) {
      _stopPeriodicSend();
      _bridge.send('close_port');
      return;
    }
    final port = _selectedPort;
    if (port == null) {
      _showMessage('未发现可用串口，请连接设备后刷新。');
      _bridge.send('scan_ports');
      return;
    }
    _bridge.send('open_port', {
      'port': port.port,
      'baudRate': int.parse(_baudRate),
      'dataBits': int.parse(_dataBits),
      'stopBits': int.parse(_stopBits),
      'parity': switch (_parity) {
        '奇 Odd' => 'odd',
        '偶 Even' => 'even',
        _ => 'none',
      },
      'flowControl': switch (_flowControl) {
        'RTS/CTS' => 'rts_cts',
        'XON/XOFF' => 'xon_xoff',
        _ => 'none',
      },
    });
  }

  void _toggleSendPanel() {
    if (_sendPanelExpanded && _periodicSending) _stopPeriodicSend();
    setState(() => _sendPanelExpanded = !_sendPanelExpanded);
    _sendPanelExpanded
        ? _sendPanelFadeController.forward()
        : _sendPanelFadeController.reverse();
  }

  void _togglePortConfiguration() {
    if (_portConfigurationExpanded) {
      _connectionPulseController.forward(from: 0);
    }
    setState(() => _portConfigurationExpanded = !_portConfigurationExpanded);
  }

  void _selectSendMode(SendMode mode) {
    if (_periodicSending && mode != SendMode.periodic) _stopPeriodicSend();
    setState(() => _sendMode = mode);
  }

  void _queueCommand() {
    if (_commandController.text.trim().isEmpty) return;
    _showMessage('已加入队列（队列执行将在 Phase 4 接入）');
    _commandController.clear();
  }

  void _sendToPort() {
    if (!_connected) {
      _showMessage('请先打开串口。');
      return;
    }
    _sendBytes(_commandBytes);
  }

  String get _commandBytes => _commandController.text.trim().isEmpty
      ? 'AA 55 A0 00 00 00 00 00 00 00 00 00'
      : _commandController.text.trim().toUpperCase();

  void _sendBytes(String bytes) => _bridge.send('write_data', {'bytes': bytes});

  void _togglePeriodicSend() {
    if (_periodicSending) {
      _stopPeriodicSend();
      return;
    }
    if (!_connected) {
      _showMessage('请先打开串口。');
      return;
    }
    final intervalMilliseconds = int.tryParse(_periodicIntervalController.text);
    if (intervalMilliseconds == null ||
        intervalMilliseconds < 10 ||
        intervalMilliseconds > 3600000) {
      _showMessage('周期请输入 10–3600000 ms。');
      return;
    }
    final bytes = _commandBytes;
    _sendBytes(bytes);
    _periodicSendTimer = Timer.periodic(
      Duration(milliseconds: intervalMilliseconds),
      (_) {
        if (_connected) {
          _sendBytes(bytes);
        } else {
          _stopPeriodicSend();
        }
      },
    );
    setState(() => _periodicSending = true);
    _showMessage('已开始周期发送：每 $intervalMilliseconds ms 一次');
  }

  void _stopPeriodicSend() {
    if (!_periodicSending && _periodicSendTimer == null) return;
    _periodicSendTimer?.cancel();
    _periodicSendTimer = null;
    if (mounted) setState(() => _periodicSending = false);
    _showMessage('周期发送已停止');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(children: [
      Scaffold(
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
            _appAction(Icons.settings_outlined, '设置', _showSettings),
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
      ),
      if (_notificationMessage case final message?)
        _transientNotification(message, scheme),
    ]);
  }

  Widget _transientNotification(String message, ColorScheme scheme) =>
      Positioned(
        left: 0,
        right: 0,
        bottom: 42,
        child: Center(
          child: MouseRegion(
            opaque: false,
            onEnter: (_) => setState(() => _notificationHovered = true),
            child: IgnorePointer(
              ignoring: _notificationHovered,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 140),
                opacity: _notificationHovered ? .16 : 1,
                child: Material(
                  color: scheme.surfaceContainerHighest,
                  elevation: 6,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    child: Text(message,
                        style: TextStyle(color: scheme.onSurface)),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

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
                  ? '${_selectedPort?.port ?? 'COM'} · $_baudRate · $_dataBits-$_parityCode-$_stopBits'
                  : (_connecting ? '连接中…' : '未连接'),
              style: const TextStyle(
                  fontFamily: HcomTheme.latinFontFamily, fontSize: 12)),
          if (!_portConfigurationExpanded) ...[
            const SizedBox(width: 4),
            Tooltip(
              message: '展开串口配置',
              child: InkWell(
                borderRadius: BorderRadius.circular(99),
                onTap: _togglePortConfiguration,
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Icon(Icons.keyboard_arrow_down_rounded,
                      size: 18,
                      color: _connected ? accent : scheme.onSurfaceVariant),
                ),
              ),
            ),
          ],
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
          if (value == 6) {
            unawaited(_showSettings());
            return;
          }
          if (value != 0) _showMessage('仅 UART/COM 在 v1 范围内');
          setState(() => _leftRailIndex = value);
        },
        scheme: scheme,
        side: _RailSide.left,
        expanded: _leftRailExpanded,
        onToggle: () => setState(() => _leftRailExpanded = !_leftRailExpanded),
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
        side: _RailSide.right,
        expanded: _rightRailExpanded,
        onToggle: () =>
            setState(() => _rightRailExpanded = !_rightRailExpanded),
      );

  Widget _workspace(ColorScheme scheme) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _portConfiguration(scheme),
          AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Easing.standard,
              height: _portConfigurationExpanded ? 14 : 0),
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
          return AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Easing.emphasizedDecelerate,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              switchInCurve: Easing.standard,
              switchOutCurve: Easing.standard,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SizeTransition(
                    sizeFactor: animation,
                    alignment: Alignment.topCenter,
                    child: child),
              ),
              child: _portConfigurationExpanded
                  ? Card(
                      key: const ValueKey('port-configuration'),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            _portField(portWidth),
                            if (showIdentity && _selectedPort != null)
                              _deviceIdentity(portWidth, scheme),
                            _selectField(
                                '波特率',
                                _baudRate,
                                const [
                                  '9600',
                                  '38400',
                                  '57600',
                                  '115200',
                                  '921600'
                                ],
                                (value) => setState(() => _baudRate = value)),
                            _selectField(
                                '数据位',
                                _dataBits,
                                const ['5', '6', '7', '8'],
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
                                (value) =>
                                    setState(() => _flowControl = value)),
                            FilledButton.icon(
                              style: _connected
                                  ? FilledButton.styleFrom(
                                      backgroundColor: scheme.error,
                                      foregroundColor: scheme.onError)
                                  : null,
                              onPressed: _connecting ? null : _toggleConnection,
                              icon: Icon(_connected
                                  ? Icons.link_off_rounded
                                  : Icons.link_rounded),
                              label: Text(_connected
                                  ? '关闭端口'
                                  : (_connecting ? '连接中…' : '打开端口')),
                            ),
                            IconButton(
                              tooltip: '收起串口配置',
                              onPressed: _togglePortConfiguration,
                              icon: const Icon(Icons.keyboard_arrow_up_rounded),
                            ),
                          ],
                        ),
                      ),
                    )
                  : const SizedBox(key: ValueKey('port-configuration-hidden')),
            ),
          );
        },
      );

  Widget _portField(double width) {
    final selected = _selectedPort;
    if (selected == null) {
      return SizedBox(
        width: width,
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: _connecting ? null : () => _bridge.send('scan_ports'),
          child: const InputDecorator(
            isEmpty: false,
            decoration: InputDecoration(labelText: '串口', isDense: true),
            child: Row(children: [
              Expanded(child: Text('未发现串口，点击刷新')),
              Icon(Icons.refresh_rounded),
            ]),
          ),
        ),
      );
    }
    return SizedBox(
      width: width,
      child: _HcomPopupField<_SerialPort>(
        width: width,
        label: '串口',
        value: selected,
        options: _ports,
        textOf: (port) => '${port.port} · ${port.description}',
        iconOf: (port) => port.icon,
        onChanged: _connected || _connecting
            ? null
            : (port) => setState(() => _selectedPort = port),
      ),
    );
  }

  Widget _deviceIdentity(double width, ColorScheme scheme) => SizedBox(
        width: width,
        child: Tooltip(
          message: '硬件 ID: ${_selectedPort!.hardwareId}',
          child: Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
                border: Border.all(color: scheme.outlineVariant),
                borderRadius: BorderRadius.circular(8)),
            child: Row(children: [
              Icon(_selectedPort!.icon, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                  child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(_selectedPort!.description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w500)),
                    Text(_selectedPort!.hardwareId,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontFamily: HcomTheme.latinFontFamily,
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
          onChanged: _connected || _connecting ? null : onChanged,
        ),
      );

  void _clearLog() {
    if (_entries.isEmpty) return;
    setState(_entries.clear);
    _showMessage('已清除当前日志');
  }

  Future<void> _copySelectedLog() async {
    final selectedText = _selectedLogText;
    if (selectedText == null || selectedText.isEmpty) return;
    final text = formatSelectedLogCopy(
      _entries,
      selectedText,
      _timeZoneOffsetMinutes,
    );
    await Clipboard.setData(ClipboardData(text: text));
  }

  Widget _logContextMenu(
    BuildContext context,
    SelectableRegionState selectableRegionState,
  ) {
    final items = selectableRegionState.contextMenuButtonItems
        .map(
          (item) => item.type == ContextMenuButtonType.copy
              ? ContextMenuButtonItem(
                  type: ContextMenuButtonType.copy,
                  onPressed: () {
                    unawaited(_copySelectedLog());
                    selectableRegionState.hideToolbar();
                  },
                )
              : item,
        )
        .toList();
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: selectableRegionState.contextMenuAnchors,
      buttonItems: items,
    );
  }

  Widget _hexStream(ColorScheme scheme) => Container(
        decoration: BoxDecoration(
            color: scheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(16)),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 8, 2),
            child: Row(children: [
              Text('实时数据',
                  style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                      fontWeight: FontWeight.w500)),
              const SizedBox(width: 8),
              Text('可拖选复制',
                  style: TextStyle(
                      color: scheme.onSurfaceVariant.withValues(alpha: .72),
                      fontSize: 11)),
              const Spacer(),
              Tooltip(
                message: _showLineNumbers ? '隐藏日志行号' : '显示日志行号',
                child: FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 34),
                      padding: const EdgeInsets.symmetric(horizontal: 12)),
                  onPressed: () =>
                      setState(() => _showLineNumbers = !_showLineNumbers),
                  icon: Icon(
                      _showLineNumbers
                          ? Icons.format_list_numbered_rtl_rounded
                          : Icons.format_list_numbered_rounded,
                      size: 18),
                  label: Text(_showLineNumbers ? '隐藏行号' : '显示行号'),
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: '清除当前 RX/TX 日志',
                child: FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 34),
                      padding: const EdgeInsets.symmetric(horizontal: 12)),
                  onPressed: _entries.isEmpty ? null : _clearLog,
                  icon: const Icon(Icons.delete_sweep_rounded, size: 18),
                  label: const Text('清除日志'),
                ),
              ),
            ]),
          ),
          Expanded(
            child: Actions(
              actions: {
                CopySelectionTextIntent:
                    CallbackAction<CopySelectionTextIntent>(
                  onInvoke: (_) {
                    unawaited(_copySelectedLog());
                    return null;
                  },
                ),
              },
              child: SelectionArea(
                onSelectionChanged: (content) =>
                    _selectedLogText = content?.plainText,
                contextMenuBuilder: _logContextMenu,
                child: _entries.isEmpty
                    ? Center(
                        child: Text('打开串口后，实时 RX/TX 数据将在此显示',
                            style: TextStyle(color: scheme.onSurfaceVariant)))
                    : ListView.builder(
                        controller: _streamController,
                        padding: const EdgeInsets.all(8),
                        itemCount: _entries.length,
                        itemBuilder: (_, index) =>
                            _entryRow(_entries[index], scheme, index),
                      ),
              ),
            ),
          ),
        ]),
      );

  Widget _entryRow(SerialEntry entry, ColorScheme scheme, int index) {
    final isRx = entry.direction == SerialDirection.rx;
    final directionLabel = hexDirectionLabel(entry.direction);
    final accent = isRx
        ? (widget.isDark ? HcomTheme.rxDark : HcomTheme.rxLight)
        : (widget.isDark ? HcomTheme.txDark : HcomTheme.txLight);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(children: [
            if (_showLineNumbers) ...[
              SelectionContainer.disabled(
                child: SizedBox(
                  width: 36,
                  child: Text('${index + 1}',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 11.5,
                          fontFamily: HcomTheme.latinFontFamily)),
                ),
              ),
              const SizedBox(width: 12),
            ],
            Container(
                width: 68,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: accent.withValues(alpha: .20),
                    borderRadius: BorderRadius.circular(99)),
                child: Text(directionLabel,
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
                        fontFamily: HcomTheme.latinFontFamily))),
            const SizedBox(width: 12),
            Expanded(
                child: Text(entry.hex,
                    style: TextStyle(
                        color: scheme.onSurface,
                        fontFamily: HcomTheme.latinFontFamily,
                        fontSize: 12.5))),
            const SizedBox(width: 12),
            SelectionContainer.disabled(
              child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                      color: scheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(8)),
                  child: Text('${entry.byteCount} B',
                      style: TextStyle(
                          fontSize: 11, color: scheme.onSurfaceVariant))),
            ),
          ]),
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
                                fontFamily: HcomTheme.latinFontFamily))
                      ]))));

  Widget _sendPanel(ColorScheme scheme, {required bool compact}) => Card(
        margin: EdgeInsets.zero,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              16, _sendPanelExpanded ? 10 : 0, 16, _sendPanelExpanded ? 12 : 0),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Easing.standard,
            child: _sendPanelExpanded
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _sendPanelHeader(),
                      FadeTransition(
                        opacity: CurvedAnimation(
                            parent: _sendPanelFadeController,
                            curve: Easing.standard),
                        child: Column(children: [
                          if (!compact) ...[
                            const SizedBox(height: 8),
                            _queueRow('AA 55 A0 00 00 00 00 00 00 00 00 00',
                                '间隔 200ms\n心跳', scheme),
                            const SizedBox(height: 6),
                            _queueRow('AA 55 01 01 04 00 41 42 20 1A',
                                '立即\n查询状态', scheme),
                          ],
                          const SizedBox(height: 8),
                          _sendCommandBar(scheme),
                        ]),
                      ),
                    ],
                  )
                : _sendCommandBar(scheme, collapsed: true),
          ),
        ),
      );

  Widget _sendPanelHeader() => Row(children: [
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
                label: Text('触发')),
            ButtonSegment(
                value: SendMode.periodic,
                icon: Icon(Icons.timer, size: 17),
                label: Text('周期')),
          ],
          selected: {_sendMode},
          onSelectionChanged: (value) => _selectSendMode(value.first),
        ),
        IconButton(
          tooltip: '收起发送面板',
          onPressed: _toggleSendPanel,
          icon: const Icon(Icons.keyboard_arrow_down_rounded),
        ),
      ]);

  Widget _sendCommandBar(ColorScheme scheme, {bool collapsed = false}) {
    final periodicMode = _sendMode == SendMode.periodic;
    return Row(children: [
      Expanded(
        child: TextField(
          controller: _commandController,
          decoration: const InputDecoration(
            hintText: '输入 HEX 命令，例如 AA 55 01 01 04 00 41 42 20 1A',
            isDense: true,
          ),
        ),
      ),
      if (periodicMode) ...[
        const SizedBox(width: 10),
        Tooltip(
          message: '周期范围：10 ms–1 h',
          child: SizedBox(
            width: 108,
            child: TextField(
              controller: _periodicIntervalController,
              enabled: !_periodicSending,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: const TextStyle(
                  fontFamily: HcomTheme.latinFontFamily, fontSize: 13),
              decoration: const InputDecoration(
                labelText: '周期',
                suffixText: 'ms',
                isDense: true,
              ),
            ),
          ),
        ),
      ],
      const SizedBox(width: 10),
      FilledButton.tonalIcon(
          onPressed: _queueCommand,
          icon: const Icon(Icons.add_rounded),
          label: const Text('队列')),
      const SizedBox(width: 10),
      FilledButton.icon(
        style: periodicMode && _periodicSending
            ? FilledButton.styleFrom(
                backgroundColor: scheme.errorContainer,
                foregroundColor: scheme.onErrorContainer)
            : null,
        onPressed: _connected
            ? (periodicMode ? _togglePeriodicSend : _sendToPort)
            : null,
        icon: Icon(periodicMode
            ? (_periodicSending ? Icons.stop : Icons.play_arrow)
            : Icons.send_rounded),
        label: Text(periodicMode ? (_periodicSending ? '停止周期' : '开始周期') : '发送'),
      ),
      if (collapsed) ...[
        const SizedBox(width: 6),
        IconButton.filledTonal(
          tooltip: '展开完整发送面板',
          onPressed: _toggleSendPanel,
          icon: const Icon(Icons.keyboard_arrow_up_rounded),
        ),
      ],
    ]);
  }

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
                      fontFamily: HcomTheme.latinFontFamily, fontSize: 12.5))),
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
                    fontFamily: HcomTheme.latinFontFamily,
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
      formatDisplayTimestamp(value, _timeZoneOffsetMinutes);
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
      fontFamily: useMono ? HcomTheme.latinFontFamily : null,
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
    required this.kind,
  });

  static _SerialPort? fromCore(Map<dynamic, dynamic> value) {
    final port = value['port'];
    if (port is! String || port.isEmpty) return null;
    return _SerialPort(
      port: port,
      description: value['description']?.toString() ?? 'Serial Port',
      hardwareId: value['hardwareId']?.toString() ?? 'Unknown',
      kind: value['kind']?.toString() ?? 'serial',
    );
  }

  final String port;
  final String description;
  final String hardwareId;
  final String kind;

  IconData get icon => switch (kind) {
        'bluetooth' => Icons.bluetooth_rounded,
        'usb' => Icons.usb_rounded,
        _ => Icons.settings_input_component_rounded,
      };
}

class _RailDestination {
  const _RailDestination(this.icon, this.label);

  final IconData icon;
  final String label;
}

enum _RailSide { left, right }

/// M3 rail with an explicitly timed, shared selection pill.
class _AnimatedRail extends StatefulWidget {
  const _AnimatedRail({
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
    required this.scheme,
    required this.side,
    required this.expanded,
    required this.onToggle,
  });

  final List<_RailDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final ColorScheme scheme;
  final _RailSide side;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  State<_AnimatedRail> createState() => _AnimatedRailState();
}

class _AnimatedRailState extends State<_AnimatedRail> {
  bool _hovering = false;

  static const _itemHeight = 66.0;

  @override
  Widget build(BuildContext context) {
    final controlOnLeft = widget.side == _RailSide.right;
    final collapseIcon = widget.side == _RailSide.left
        ? Icons.chevron_left
        : Icons.chevron_right;
    final expandIcon = widget.side == _RailSide.left
        ? Icons.chevron_right
        : Icons.chevron_left;
    final tooltip = widget.expanded
        ? '收起${widget.side == _RailSide.left ? '左侧' : '右侧'} Dock'
        : '展开${widget.side == _RailSide.left ? '左侧' : '右侧'} Dock';
    final control = AnimatedOpacity(
      duration: const Duration(milliseconds: 180),
      opacity: _hovering ? 1 : .62,
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: widget.scheme.surfaceContainerHighest.withValues(alpha: .96),
          shape: StadiumBorder(
              side: BorderSide(color: widget.scheme.outlineVariant)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onToggle,
            child: SizedBox(
              width: 34,
              height: 42,
              child: Icon(widget.expanded ? collapseIcon : expandIcon,
                  size: 22, color: widget.scheme.primary),
            ),
          ),
        ),
      ),
    );

    final rail = widget.expanded
        ? Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
            child: Material(
              color: widget.scheme.surfaceContainerLow,
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
                  top: 4 + widget.selectedIndex * _itemHeight,
                  height: 58,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                          color: widget.scheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(100)),
                    ),
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: List.generate(widget.destinations.length, (index) {
                    final destination = widget.destinations[index];
                    final selected = index == widget.selectedIndex;
                    return SizedBox(
                      height: _itemHeight,
                      width: double.infinity,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(100),
                        onTap: () => widget.onSelected(index),
                        child: Column(
                            mainAxisAlignment: MainAxisAlignment.start,
                            children: [
                              const SizedBox(height: 14),
                              Icon(destination.icon,
                                  size: 20,
                                  color: selected
                                      ? widget.scheme.onSecondaryContainer
                                      : widget.scheme.onSurfaceVariant),
                              const SizedBox(height: 3),
                              Text(destination.label,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w500,
                                      color: selected
                                          ? widget.scheme.onSurface
                                          : widget.scheme.onSurfaceVariant)),
                            ]),
                      ),
                    );
                  }),
                ),
              ]),
            ),
          )
        : SizedBox(
            height: widget.destinations.length * _itemHeight + 32,
            child: Align(
              alignment: Alignment.topCenter,
              child: Container(
                width: 8,
                height: double.infinity,
                decoration: BoxDecoration(
                    color: widget.scheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(99)),
              ),
            ),
          );

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Easing.standard,
        width: widget.expanded ? 112 : 44,
        child: Stack(clipBehavior: Clip.none, children: [
          Padding(
            padding: EdgeInsets.only(
                left: controlOnLeft ? 24 : 0, right: controlOnLeft ? 0 : 24),
            child: rail,
          ),
          Positioned(
            top: 16 + (widget.destinations.length * _itemHeight - 42) / 2,
            left: controlOnLeft ? 0 : null,
            right: controlOnLeft ? null : 0,
            child: control,
          ),
        ]),
      ),
    );
  }
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
                                        fontFamily: HcomTheme.latinFontFamily)),
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
