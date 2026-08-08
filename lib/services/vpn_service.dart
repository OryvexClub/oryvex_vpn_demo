import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'wireguard_service.dart';
import 'oryvex_service.dart';
import 'xray_service.dart';
import 'vpn_core.dart';
import 'ipinfo_service.dart';
import '../utils/error_handler.dart';
import 'system_proxy.dart';
import 'system_check_service.dart';

enum VpnStage {
  idle,
  fetchingConfig,
  installingTunnel,
  connected,
  error,
  disconnecting,
}

/// Connection mode: AmneziaWG (full tunnel) or Oryvex Core (recommended).
enum VpnMode {
  wireGuard,   // AmneziaWG full tunnel
  oryvexCore,  // Oryvex binary with protocol fallback (recommended)
}

/// Immutable result of a real detection pass. "Connected" is only ever true
/// when OryvexVPN's own tunnel (WireGuard service or oryvex.exe on :1819) is
/// genuinely up — never because a foreign VPN/proxy app is running.
class VpnStateSnapshot {
  final bool isOryvexConnected;
  final bool isWireGuardConnected;
  final bool externalVpnActive;

  const VpnStateSnapshot({
    required this.isOryvexConnected,
    required this.isWireGuardConnected,
    required this.externalVpnActive,
  });

  bool get isGenuinelyConnected => isOryvexConnected || isWireGuardConnected;
}

class VPNService extends ChangeNotifier {
  VpnStage _stage = VpnStage.idle;
  String _statusMessage = 'Click to connect';
  String? _lastError;
  ConnectionStats _stats = ConnectionStats.initial();
  Timer? _statsTimer;
  Timer? _connectionCheckTimer;
  Timer? _systemCheckTimer;

  DateTime? _connectedAt;
  int _totalDownload = 0;
  int _totalUpload = 0;

  // Previous stats for speed calculation.
  int _previousRxBytes = 0;
  int _previousTxBytes = 0;
  DateTime _lastStatsUpdate = DateTime.now();

  // Auto-recovery bookkeeping.
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 3;
  static const String _tag = 'VPNService';

  VpnMode _vpnMode = VpnMode.wireGuard;
  VpnMode get vpnMode => _vpnMode;
  bool get isOryvexMode => _vpnMode == VpnMode.oryvexCore;
  bool get isWireGuardMode => _vpnMode == VpnMode.wireGuard;

  OryvexProtocol _oryvexProtocol = OryvexProtocol.auto;
  OryvexProtocol get oryvexProtocol => _oryvexProtocol;

  void setOryvexProtocol(OryvexProtocol protocol) {
    if (isConnecting || isConnected) return;
    _oryvexProtocol = protocol;
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString('oryvex_protocol', protocol.name);
    });
    VpnLogger.info(_tag, 'Oryvex protocol set to: ${protocol.name}');
    notifyListeners();
  }

  String _antiDpiPreset = 'standard';
  String get antiDpiPreset => _antiDpiPreset;

  void setAntiDpiPreset(String preset) {
    _antiDpiPreset = preset;
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString('anti_dpi_preset', preset);
    });
    notifyListeners();
  }

  void setVpnMode(VpnMode mode) {
    if (isConnecting || isConnected) return; // Can't switch while active
    _vpnMode = mode;
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString('vpn_mode', mode == VpnMode.wireGuard ? 'wireGuard' : 'oryvexCore');
    });
    VpnLogger.info(_tag, 'VPN mode set to: ${mode == VpnMode.wireGuard ? "WireGuard" : "Oryvex Core"}');
    notifyListeners();
  }

  VpnStage get stage => _stage;
  bool get isConnected => _stage == VpnStage.connected;
  bool get isConnecting =>
      _stage == VpnStage.fetchingConfig || _stage == VpnStage.installingTunnel;
  String get statusMessage => _statusMessage;
  String? get lastError => _lastError;
  ConnectionStats get stats => _stats;
  DateTime? get connectedAt => _connectedAt;
  int get totalDownload => _totalDownload;
  int get totalUpload => _totalUpload;
  String get currentEndpoint => WireGuardService.currentEndpoint?.hostPort ?? '—';

  VpnStateSnapshot _snapshot = const VpnStateSnapshot(
    isOryvexConnected: false,
    isWireGuardConnected: false,
    externalVpnActive: false,
  );
  VpnStateSnapshot get snapshot => _snapshot;

  /// True when OUR oryvex process owns port 1819 (never a foreign app).
  bool get isOryvexConnected => _snapshot.isOryvexConnected;

  /// True when the AmneziaWG/oryvexvpn Windows tunnel service is RUNNING.
  bool get isWireGuardConnected => _snapshot.isWireGuardConnected;

  /// True when an external VPN/proxy app (v2ray, Clash, ...) is running.
  bool get externalVpnActive => _snapshot.externalVpnActive;

  /// True when OryvexVPN's own tunnel is genuinely up.
  bool get isGenuinelyConnected => _snapshot.isGenuinelyConnected;

  /// Recent connecting-stage messages (e.g. "Finding fastest server...") so
  /// the UI can show a live step strip while connecting. Most recent last.
  final List<String> _stageHistory = [];
  List<String> get stageHistory => List.unmodifiable(_stageHistory);

  /// Representative 0..1 progress for the connecting ring animation.
  /// Maps the coarse connection stages to a meaningful sweep.
  double get connectProgress {
    switch (_stage) {
      case VpnStage.fetchingConfig:
        return 0.38;
      case VpnStage.installingTunnel:
        return 0.72;
      default:
        return 0.0;
    }
  }

  /// Human-readable connection duration, or '—' when not connected.
  String get connectedDuration {
    final at = _connectedAt;
    if (at == null) return '—';
    final d = DateTime.now().difference(at);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  VPNService() {
    _loadSettings();
    _startSystemMonitoring();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _antiDpiPreset = prefs.getString('anti_dpi_preset') ?? 'standard';
    final modeStr = prefs.getString('vpn_mode') ?? 'wireGuard';
    _vpnMode = modeStr == 'oryvexCore' ? VpnMode.oryvexCore : VpnMode.wireGuard;
    final protocolStr = prefs.getString('oryvex_protocol') ?? 'auto';
    _oryvexProtocol = OryvexProtocol.values.firstWhere(
      (p) => p.name == protocolStr,
      orElse: () => OryvexProtocol.auto,
    );
    notifyListeners();
  }

  void _updateStatus(String msg) {
    _statusMessage = msg;
    // While connecting, keep a rolling trail of the stage messages so the UI
    // can show a live "step strip" (most recent last).
    if (_stage == VpnStage.fetchingConfig || _stage == VpnStage.installingTunnel) {
      if (_stageHistory.isEmpty || _stageHistory.last != msg) {
        _stageHistory.add(msg);
        if (_stageHistory.length > 6) _stageHistory.removeAt(0);
      }
    }
    VpnLogger.info(_tag, 'Status: $msg');
    notifyListeners();
  }

  /// Runs a real detection pass and caches the result in [_snapshot].
  /// "Connected" is only true when our own tunnel (WireGuard service or
  /// oryvex.exe port 1819) is genuinely up.
  Future<VpnStateSnapshot> detectState() async {
    final results = await Future.wait<Object>([
      OryvexService.isPort1819OwnedByOryvex(),
      WireGuardService.isConnected(),
      SystemCheckService.isExternalVpnRunning(),
    ]);
    final snap = VpnStateSnapshot(
      isOryvexConnected: results[0] as bool,
      isWireGuardConnected: results[1] as bool,
      externalVpnActive: results[2] as bool,
    );
    _snapshot = snap;
    VpnLogger.debug(_tag,
        'detectState: oryvex=${snap.isOryvexConnected} wg=${snap.isWireGuardConnected} external=${snap.externalVpnActive}');
    return snap;
  }

  Future<void> initStatus() async {
    VpnLogger.info(_tag, 'initStatus: checking current state...');
    final snap = await detectState();
    if (snap.isGenuinelyConnected) {
      _stage = VpnStage.connected;
      _connectedAt = DateTime.now();
      _statusMessage = 'Connected';
      _startStatsMonitoring();
      _startConnectionMonitoring();
      VpnLogger.info(_tag,
          'initStatus: CONNECTED (wg=${snap.isWireGuardConnected} oryvex=${snap.isOryvexConnected})');
    } else {
      _stage = VpnStage.idle;
      _statusMessage = 'Click to connect';
      // A leftover adapter with no running tunnel (e.g. after a crash) must be
      // cleaned up instead of being mistaken for an active connection.
      if (await VpnCore.interfaceExists()) {
        VpnLogger.warn(_tag, 'Leftover ${VpnCore.tunnelName} adapter without running tunnel; removing...');
        await VpnCore.comprehensiveCleanup().catchError((_) {});
      }
    }
    notifyListeners();
  }

  void _startStatsMonitoring() {
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      await _updateStats();
    });
    _updateStats();
  }

  void _stopStatsMonitoring() {
    _statsTimer?.cancel();
    _statsTimer = null;
  }

  void _startSystemMonitoring() {
    _systemCheckTimer?.cancel();
    _systemCheckTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      // 1) Refresh the live detection snapshot. External VPN/proxy apps are a
      //    non-blocking amber banner (see home_screen), never a hard disconnect.
      final snap = await detectState();
      final clockSynced = await SystemCheckService.isClockSynced();

      final stateChanged = snap.externalVpnActive != _snapshot.externalVpnActive ||
          snap.isGenuinelyConnected != _snapshot.isGenuinelyConnected;
      _snapshot = snap;
      if (stateChanged) {
        notifyListeners();
      }

      // 2) Clock skew is the one case that still warrants a hard error: a
      //    wrong clock silently breaks TLS/WARP handshakes.
      if (!clockSynced && (isConnected || isConnecting)) {
        _stage = VpnStage.error;
        _lastError = 'Disconnected: system clock out of sync';
        _statusMessage = 'Disconnected';
        _stopStatsMonitoring();
        _stopConnectionMonitoring();
        await WireGuardService.disconnect();
        notifyListeners();
      }
    });
  }

  void _startConnectionMonitoring() {
    _connectionCheckTimer?.cancel();
    _connectionCheckTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      await _checkConnectionStatus();
    });
  }

  void _stopConnectionMonitoring() {
    _connectionCheckTimer?.cancel();
    _connectionCheckTimer = null;
  }

  Future<void> _checkConnectionStatus() async {
    if (_stage != VpnStage.connected) return;

    // Check liveness based on the current VPN mode — using strict ownership
    // checks so a foreign proxy app can never masquerade as our tunnel.
    bool alive = false;
    if (isOryvexMode) {
      alive = await OryvexService.isPort1819OwnedByOryvex();
    } else {
      alive = await WireGuardService.isConnected();
    }

    if (alive) {
      // Tunnel is alive — reset reconnect counter
      _reconnectAttempts = 0;
      return;
    }

    // Service is dead — only then consider it dropped
    VpnLogger.warn(_tag, 'Tunnel service is not running');

    // Tunnel dropped unexpectedly. Try to auto-recover a few times.
    // Ensure we are waiting at least 25 seconds since connected before testing dropping connection
    if (_connectedAt != null && DateTime.now().difference(_connectedAt!).inSeconds < 25) {
      return; // Give it some time to establish and report status properly
    }

    _reconnectAttempts++;
    VpnLogger.warn(_tag,
        'Connection dropped! Attempt $_reconnectAttempts/$_maxReconnectAttempts');
    if (_reconnectAttempts <= _maxReconnectAttempts) {
      _statusMessage = 'Connection lost, retrying ($_reconnectAttempts/$_maxReconnectAttempts)...';
      notifyListeners();
      await _reconnect();
    } else {
      _reconnectAttempts = 0;
      _stage = VpnStage.error;
      _lastError = 'Connection dropped unexpectedly';
      _statusMessage = 'Disconnected';
      _stopStatsMonitoring();
      _stopConnectionMonitoring();
      notifyListeners();
    }
  }

  Future<void> _reconnect() async {
    VpnLogger.info(_tag, 'Starting auto-reconnect...');
    _stopStatsMonitoring();
    _stopConnectionMonitoring();
    try {
      // Stop Xray first (it depends on oryvex SOCKS5)
      await XrayService.stop();

      // Disconnect oryvex if it's running
      await OryvexService.disconnect();
      await WireGuardService.disconnect();

      // Reconnect using the selected mode
      if (isOryvexMode && await OryvexService.isAvailable()) {
        VpnLogger.info(_tag, 'Reconnecting via oryvex protocol fallback');
        await OryvexService.connectWithFallback(
          onProgress: (msg, stage) {
            _stage = stage;
            _statusMessage = msg;
            notifyListeners();
          },
        );

        // Start Xray core as front-facing proxy
        if (await XrayService.isAvailable()) {
          VpnLogger.info(_tag, 'Starting Xray core after reconnect...');
          await XrayService.start();
        }
      } else {
        // WireGuard mode or oryvex unavailable: use AmneziaWG
        await WireGuardService.connectWithProgress(
          isFullTunnel: true,
          antiDpiPreset: _antiDpiPreset,
          onProgress: (msg, stage) {
            _stage = stage;
            _statusMessage = msg;
            notifyListeners();
          },
        );
      }

      final ok = await WireGuardService.isConnected() || await OryvexService.isPort1819OwnedByOryvex();
      if (ok) {
        VpnLogger.info(_tag, 'Auto-reconnect SUCCESS');
        _stage = VpnStage.connected;
        _connectedAt = DateTime.now();
        _statusMessage = 'Connected';
        _startStatsMonitoring();
        _startConnectionMonitoring();
      } else {
        VpnLogger.warn(_tag, 'Auto-reconnect: still no handshake');
      }
    } catch (e) {
      VpnLogger.error(_tag, 'Auto-reconnect failed: $e');
    }
    notifyListeners();
  }

  // Counter to avoid fetching IP every cycle
  int _statsCycleCount = 0;

  Future<void> _updateStats() async {
    if (!isConnected) return;

    final tunnelStats = await ErrorHandler.tryCatch(
      () => WireGuardService.getTunnelStats(),
      fallback: {'rx_bytes': 0, 'tx_bytes': 0, 'handshake_age': null},
      context: 'Get Tunnel Stats',
    );

    final rxBytes = (tunnelStats?['rx_bytes'] as int?) ?? 0;
    final txBytes = (tunnelStats?['tx_bytes'] as int?) ?? 0;
    _totalDownload = rxBytes;
    _totalUpload = txBytes;

    final now = DateTime.now();
    final timeDiff = now.difference(_lastStatsUpdate).inSeconds;

    double downloadSpeed = 0.0;
    double uploadSpeed = 0.0;
    if (timeDiff > 0) {
      if (rxBytes > 0 && rxBytes >= _previousRxBytes) {
        downloadSpeed = (rxBytes - _previousRxBytes) / timeDiff / 1024;
      }
      if (txBytes > 0 && txBytes >= _previousTxBytes) {
        uploadSpeed = (txBytes - _previousTxBytes) / timeDiff / 1024;
      }
      _previousRxBytes = rxBytes;
      _previousTxBytes = txBytes;
    }
    _lastStatsUpdate = now;

    // Fetch IP info only every 10 cycles (~30 seconds) to avoid rate limiting
    _statsCycleCount++;
    IPInfoModel ipInfo = _stats.ipInfo;
    if (_statsCycleCount >= 10 || _stats.ipInfo.ip == 'N/A') {
      _statsCycleCount = 0;
      ipInfo = await ErrorHandler.tryCatch(
        () => IPInfoService.getIPInfo(),
        fallback: _stats.ipInfo,
        context: 'Get IP Info',
      ) ?? _stats.ipInfo;
    }

    // Ping always updates
    final ping = await ErrorHandler.tryCatch(
      () => IPInfoService.measurePing('1.1.1.1'),
      fallback: 0,
      context: 'Measure Ping',
    );

    _stats = ConnectionStats(
      ping: (ping != null && ping > 0) ? ping : 0,
      downloadSpeed: downloadSpeed > 0 ? downloadSpeed : 0.0,
      uploadSpeed: uploadSpeed > 0 ? uploadSpeed : 0.0,
      ipInfo: ipInfo,
      timestamp: now,
    );
    notifyListeners();
  }

  Future<void> _attemptConnectionRound() async {
    // Oryvex Core mode: use oryvex binary with protocol fallback
    if (isOryvexMode && await OryvexService.isAvailable()) {
      VpnLogger.info(_tag, 'Using oryvex binary with protocol: ${_oryvexProtocol.name}');
      await OryvexService.connectWithFallback(
        onProgress: (msg, stage) {
          _stage = stage;
          AppLogger.info(msg, 'VPN');
          _updateStatus(msg);
        },
        protocol: _oryvexProtocol,
      );

      // Wait for tunnel to fully establish
      VpnLogger.info(_tag, 'Waiting for tunnel to establish...');
      await Future.delayed(const Duration(seconds: 3));

      // Verify connection — strict: our own tunnel must be genuinely up.
      final running = await WireGuardService.isConnected() || await OryvexService.isPort1819OwnedByOryvex();
      VpnLogger.info(_tag, 'Tunnel service running (oryvex): $running');

      if (!running) {
        throw const FormatException('Tunnel failed to start. Please try again.');
      }

      // Start Xray core as front-facing proxy
      if (await XrayService.isAvailable()) {
        VpnLogger.info(_tag, 'Starting Xray core as front-facing proxy...');
        _updateStatus('Starting Xray proxy...');
        await XrayService.start();
      } else {
        VpnLogger.info(_tag, 'Xray binary not available, using oryvex SOCKS5 directly');
      }

      VpnLogger.info(_tag, 'Connection established via oryvex protocol fallback');
      return;
    }

    // Fallback to AmneziaWG WireGuard if oryvex mode is not selected or not available
    VpnLogger.info(_tag, 'Using AmneziaWG WireGuard mode');

    // Always use full tunnel for WireGuard routing.
    // When in proxy mode, local proxies handle selective routing.
    await WireGuardService.connectWithProgress(
      isFullTunnel: true,
      antiDpiPreset: _antiDpiPreset,
      onProgress: (msg, stage) {
        _stage = stage;
        AppLogger.info(msg, 'VPN');
        _updateStatus(msg);
      },
    );

    // Wait for tunnel to fully establish
    VpnLogger.info(_tag, 'Waiting for tunnel to establish...');
    await Future.delayed(const Duration(seconds: 3));

    // Verify tunnel service is actually running
    final running = await WireGuardService.isConnected();
    VpnLogger.info(_tag, 'Tunnel service running: $running');

    if (!running) {
      VpnLogger.error(_tag, 'Tunnel service not running after install');
      throw const FormatException('Tunnel failed to start. Please try again.');
    }

    // Verify handshake occurred (tunnel is actually communicating)
    bool hasHandshake = false;
    try {
      final stats = await WireGuardService.getTunnelStats();
      final handshakeAge = stats['handshake_age'] as int?;
      final rx = stats['rx_bytes'] as int? ?? 0;
      final tx = stats['tx_bytes'] as int? ?? 0;
      VpnLogger.info(_tag, 'Tunnel stats: handshake_age=$handshakeAge, rx=$rx, tx=$tx');
      hasHandshake = handshakeAge != null || rx > 0 || tx > 0;
    } catch (e) {
      VpnLogger.warn(_tag, 'Could not read tunnel stats: $e');
    }

    if (!hasHandshake) {
      VpnLogger.warn(_tag, 'No handshake yet, waiting longer...');
      await Future.delayed(const Duration(seconds: 5));
      try {
        final stats = await WireGuardService.getTunnelStats();
        final handshakeAge = stats['handshake_age'] as int?;
        final rx = stats['rx_bytes'] as int? ?? 0;
        hasHandshake = handshakeAge != null || rx > 0;
        VpnLogger.info(_tag, 'Retry stats: handshake_age=$handshakeAge, rx=$rx');
      } catch (e) {
        VpnLogger.warn(_tag, 'Retry stats failed: $e');
      }
    }

    // Even without handshake yet, if service is running, consider it connected.
    // The handshake may take a moment but traffic will start flowing.
    VpnLogger.info(_tag, 'Connection established (service running=$running, handshake=$hasHandshake)');
  }

  Future<void> connect() async {
    if (isConnecting) return;

    VpnLogger.info(_tag, '=== CONNECT START ===');

    try {
      if (isConnected || _stage == VpnStage.error) {
         VpnLogger.info(_tag, 'Cleaning up previous connection state...');
         await WireGuardService.disconnect();
         await VpnCore.fullCleanup();
      }
    } catch (e) {
      VpnLogger.warn(_tag, 'Pre-connect cleanup error: $e');
    }

    AppLogger.connectionState('Connecting');
    _lastError = null;
    _reconnectAttempts = 0;

    // Save the current system proxy and disable it so the tunneled traffic
    // isn't forced through a stale local proxy (which causes
    // ERR_PROXY_CONNECTION_FAILED in browsers).
    await SystemProxyService.saveState();
    await SystemProxyService.disable();

    _stage = VpnStage.fetchingConfig;
    _statusMessage = 'Finding fastest server...';
    notifyListeners();

    int attempts = 0;
    bool connected = false;

    while (attempts < 3 && !connected) {
      attempts++;
      try {
        await _attemptConnectionRound();
        connected = true;
      } catch (e, stackTrace) {
        if (e is FormatException && attempts < 3) {
           VpnLogger.warn(_tag, 'Connection round $attempts failed verification, retrying...');
           _updateStatus('Retrying connection ($attempts/3)...');
           await WireGuardService.disconnect();
           await VpnCore.fullCleanup();
        } else {
          VpnLogger.error(_tag, '=== CONNECT FAILED: $e ===');
          AppLogger.error('Connection failed', e, stackTrace, 'VPN');
          _stage = VpnStage.error;
          _lastError = ErrorHandler.getUserFriendlyMessage(e);
          _updateStatus('Connection failed');
          _stopStatsMonitoring();
          _stopConnectionMonitoring();
          await SystemProxyService.restore();
          notifyListeners();
          return;
        }
      }
    }

    if (connected) {
      _stage = VpnStage.connected;
      _connectedAt = DateTime.now();
      _stageHistory.clear();
      _updateStatus('Connected');
      AppLogger.connectionState('Connected');
      _startStatsMonitoring();
      _startConnectionMonitoring();

      // Flush DNS so the tunnel's DNS servers take effect immediately
      VpnCore.flushDns().catchError((_) {});

      VpnLogger.info(_tag, '=== CONNECT SUCCESS ===');
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    VpnLogger.info(_tag, '=== DISCONNECT START ===');
    AppLogger.connectionState('Disconnecting');
    _stage = VpnStage.disconnecting;
    _updateStatus('Disconnecting...');
    _stopStatsMonitoring();
    _stopConnectionMonitoring();

    try {
      // Stop Xray first (it depends on oryvex SOCKS5)
      await XrayService.stop();

      // Disconnect oryvex if it's running
      await OryvexService.disconnect();

      await WireGuardService.disconnect();

      final stillConnected = await WireGuardService.isConnected();
      if (stillConnected) {
        VpnLogger.warn(_tag, 'Tunnel still running after disconnect, force killing...');
        await VpnCore.fullCleanup();
      }

      _stage = VpnStage.idle;
      _connectedAt = null;
      _stageHistory.clear();
      _totalDownload = 0;
      _totalUpload = 0;
      _previousRxBytes = 0;
      _previousTxBytes = 0;
      _stats = ConnectionStats.initial();
      _updateStatus('Disconnected');
      _lastError = null;
      AppLogger.connectionState('Disconnected');
      // Restore the system proxy that was disabled during connection.
      await SystemProxyService.restore();
      VpnLogger.info(_tag, '=== DISCONNECT SUCCESS ===');
    } catch (e, stackTrace) {
      VpnLogger.error(_tag, '=== DISCONNECT FAILED: $e ===');
      AppLogger.error('Disconnect failed', e, stackTrace, 'VPN');
      _stage = VpnStage.error;
      _lastError = ErrorHandler.getUserFriendlyMessage(e);
      _updateStatus('Disconnect failed');
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _systemCheckTimer?.cancel();
    _stopStatsMonitoring();
    _stopConnectionMonitoring();
    super.dispose();
  }
}