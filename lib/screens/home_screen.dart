import 'package:flutter/material.dart';
import 'dart:math' as math;
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import '../services/vpn_service.dart';
import '../services/oryvex_service.dart';
import '../widgets/logs_dialog.dart';
import '../theme/app_theme.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final AnimationController _glowController;
  late final AnimationController _entryController;
  late final AnimationController _brandShimmerController;
  late final AnimationController _auroraController;

  /// Drives the rotating comet sweep while connecting.
  late final AnimationController _connectProgController;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<VPNService>().initStatus();
    });

    // Pulse ring animation (breathing when connected)
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);

    // Glow intensity animation
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);

    // Entry animation (plays once on load)
    _entryController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..forward();

    // Brand shimmer animation
    _brandShimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    )..repeat();

    // Slow aurora background drift
    _auroraController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    )..repeat();

    // Connecting sweep (loops only while connecting)
    _connectProgController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _glowController.dispose();
    _entryController.dispose();
    _brandShimmerController.dispose();
    _auroraController.dispose();
    _connectProgController.dispose();
    super.dispose();
  }

  Color getStatusColor(VPNService vpn) {
    if (vpn.isConnected) return AppTheme.accent;
    if (vpn.isConnecting) return AppTheme.warning;
    if (vpn.stage == VpnStage.error) return AppTheme.error;
    return AppTheme.textSecondary;
  }

  @override
  Widget build(BuildContext context) {
    final vpn = context.watch<VPNService>();
    final color = getStatusColor(vpn);
    final active = vpn.isConnected || vpn.isConnecting;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
        child: Stack(
          children: [
            // Drifting aurora glow behind everything
            Positioned.fill(
              child: IgnorePointer(
                child: _AuroraBackground(animation: _auroraController),
              ),
            ),
            Column(
              children: [
                _buildTitleBar(vpn, color),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final compact = constraints.maxWidth < 360;
                      final hPad = compact ? 18.0 : 24.0;
                      final gap = compact ? 22.0 : 30.0;
                      final cardGap = compact ? 12.0 : 16.0;
                      return SingleChildScrollView(
                        physics: const BouncingScrollPhysics(),
                        padding: EdgeInsets.symmetric(horizontal: hPad),
                        child: Column(
                          children: [
                            SizedBox(height: compact ? 14 : 20),
                            _buildHeader(),
                            SizedBox(height: gap),
                            _buildPowerButton(vpn, color, active, compact),
                            SizedBox(height: gap),
                            _buildStatusText(vpn, color, compact),
                            if (vpn.isConnecting &&
                                vpn.stageHistory.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              _buildStageStrip(vpn),
                            ],
                            if (vpn.externalVpnActive) ...[
                              const SizedBox(height: 12),
                              _buildExternalVpnBanner(),
                            ],
                            if (vpn.lastError != null) ...[
                              SizedBox(height: compact ? 12 : 16),
                              _buildErrorBox(vpn),
                            ],
                            SizedBox(height: cardGap + 8),
                            _buildModeSelector(vpn, active),
                            SizedBox(height: cardGap + 8),
                            _buildStatsGrid(vpn, compact: compact, cardGap: cardGap),
                            const SizedBox(height: 30),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── Header with animated brand text ───────────────────────────────
  Widget _buildHeader() {
    return AnimatedBuilder(
      animation: _entryController,
      builder: (context, child) {
        return FadeTransition(
          opacity: _entryController,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.1),
              end: Offset.zero,
            ).animate(CurvedAnimation(
              parent: _entryController,
              curve: Curves.easeOutCubic,
            )),
            child: child,
          ),
        );
      },
      child: Column(
        children: [
          // Animated brand logo
          AnimatedBuilder(
            animation: _brandShimmerController,
            builder: (context, child) {
              return ShaderMask(
                shaderCallback: (Rect bounds) {
                  return LinearGradient(
                    begin: Alignment(-1.0 + 2.0 * _brandShimmerController.value, 0),
                    end: Alignment(-0.5 + 2.0 * _brandShimmerController.value, 0),
                    colors: const [
                      Colors.white,
                      AppTheme.accent,
                      Colors.white,
                    ],
                    stops: const [0.0, 0.5, 1.0],
                  ).createShader(bounds);
                },
                blendMode: BlendMode.srcIn,
                child: RichText(
                  text: const TextSpan(
                    text: 'Oryvex',
                    style: TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      letterSpacing: -1.0,
                      fontFamily: 'Inter',
                    ),
                    children: [
                      TextSpan(
                        text: 'VPN',
                        style: TextStyle(
                          color: AppTheme.accent,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 10),
          const Text(
            'Enjoy a fast, secure, and private internet experience with a simple and modern interface.',
            textAlign: TextAlign.center,
            style: AppTheme.subheadingStyle,
          ),
        ],
      ),
    );
  }

  // ── Custom title bar ──────────────────────────────────────────────
  Widget _buildTitleBar(VPNService vpn, Color color) {
    return Container(
      height: 40,
      color: Colors.transparent,
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (_) => windowManager.startDragging(),
              child: const SizedBox(height: double.infinity),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.help_outline_rounded, color: AppTheme.textMuted, size: 16),
            onPressed: () => _showAiCompatibilityDialog(context),
            splashRadius: 18,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 40),
            tooltip: 'AI Service Compatibility',
          ),
          IconButton(
            icon: const Icon(Icons.terminal_rounded, color: AppTheme.textMuted, size: 16),
            onPressed: () {
              AppTheme.showAnimatedDialog(
                context: context,
                builder: (context) => const LogsDialog(),
              );
            },
            splashRadius: 18,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 40),
            tooltip: 'Core Logs',
          ),
          IconButton(
            icon: const Icon(Icons.remove, color: AppTheme.textMuted, size: 16),
            onPressed: () => windowManager.minimize(),
            splashRadius: 18,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 40),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: AppTheme.textMuted, size: 16),
            onPressed: () => windowManager.close(),
            splashRadius: 18,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 40),
          ),
        ],
      ),
    );
  }

  // ── Status text pill ──────────────────────────────────────────────
  Widget _buildStatusText(VPNService vpn, Color color, [bool compact = false]) {
    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        final glowOpacity = 0.3 + 0.2 * _pulseController.value;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: AppTheme.containerDecoration(),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Animated pulsing dot
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color,
                  boxShadow: [
                    BoxShadow(
                      color: color.withOpacity(glowOpacity),
                      blurRadius: 10,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                vpn.statusMessage.toUpperCase(),
                style: AppTheme.statusStyle,
              ),
            ],
          ),
        );
      },
    );
  }

  // ── Live stage strip (shown while connecting) ─────────────────────
  Widget _buildStageStrip(VPNService vpn) {
    final history = vpn.stageHistory;
    final current = history.isNotEmpty ? history.last : vpn.statusMessage;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: AppTheme.glassDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.6,
                  valueColor: AlwaysStoppedAnimation(AppTheme.warning),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  current,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (history.length > 1) ...[
            const SizedBox(height: 8),
            for (final step in history.take(history.length - 1).toList().reversed)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  children: [
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 5),
                      child: Icon(Icons.check, color: AppTheme.textTertiary, size: 10),
                    ),
                    Expanded(
                      child: Text(
                        step,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.textTertiary,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  // ── Error box ─────────────────────────────────────────────────────
  Widget _buildErrorBox(VPNService vpn) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.error.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.error.withOpacity(0.25)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: AppTheme.error, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              vpn.lastError!,
              style: const TextStyle(fontSize: 13, color: AppTheme.errorLight, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  // ── External VPN/proxy banner ─────────────────────────────────────
  Widget _buildExternalVpnBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.warning.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.warning.withOpacity(0.35)),
      ),
      child: const Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: AppTheme.warning, size: 20),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'An external VPN/proxy is running.\nOryvexVPN is separate from it.',
              style: TextStyle(
                fontSize: 12,
                color: Colors.white70,
                fontWeight: FontWeight.w500,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Power button with glow ring ───────────────────────────────────
  Widget _buildPowerButton(VPNService vpn, Color color, bool active,
      [bool compact = false]) {
    final outer = compact ? 150.0 : 180.0;
    final inner = compact ? 118.0 : 140.0;
    return GestureDetector(
      onTap: vpn.isConnecting
          ? null
          : () => vpn.isConnected ? vpn.disconnect() : vpn.connect(),
      child: AnimatedBuilder(
        animation: Listenable.merge(
            [_pulseController, _glowController, _connectProgController]),
        builder: (context, child) {
          final t = _pulseController.value;
          final glowT = _glowController.value;
          // Start / stop the connecting sweep based on stage.
          if (vpn.isConnecting && !_connectProgController.isAnimating) {
            _connectProgController.repeat();
          } else if (!vpn.isConnecting && _connectProgController.isAnimating) {
            _connectProgController.stop();
            _connectProgController.value = 0;
          }

          return SizedBox(
            width: outer,
            height: outer,
            child: CustomPaint(
              painter: _RingPainter(
                color: color,
                active: active,
                progress: vpn.isConnected ? 1.0 : (vpn.isConnecting ? vpn.connectProgress : t),
                glowIntensity: active ? 0.15 + 0.1 * glowT : 0.0,
                sweepTick: _connectProgController.value,
                sweepActive: vpn.isConnecting,
              ),
              child: Center(child: child),
            ),
          );
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOutCubic,
          width: inner,
          height: inner,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppTheme.surfaceElevated,
            border: Border.all(
              color: active ? color.withOpacity(0.6) : AppTheme.border,
              width: active ? 2 : 1,
            ),
            boxShadow: [
              if (active)
                BoxShadow(
                  color: color.withOpacity(0.12 + 0.05 * _glowController.value),
                  blurRadius: 40,
                  spreadRadius: 5,
                ),
            ],
          ),
          child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 400),
              switchInCurve: Curves.easeOutBack,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, anim) => ScaleTransition(
                scale: anim,
                child: FadeTransition(opacity: anim, child: child),
              ),
              child: vpn.isConnecting
                  ? Icon(
                      Icons.power_settings_new_rounded,
                      key: const ValueKey('connecting'),
                      size: 56,
                      color: AppTheme.warning,
                    )
                  : Icon(
                      vpn.isConnected ? Icons.bolt : Icons.power_settings_new_rounded,
                      key: ValueKey(vpn.isConnected ? 'connected' : 'idle'),
                      size: vpn.isConnected ? 52 : 56,
                      color: active ? color : Colors.white24,
                    ),
            ),
        ),
      ),
    );
  }

  // ── AI compatibility dialog ───────────────────────────────────────
  void _showAiCompatibilityDialog(BuildContext context) {
    AppTheme.showAnimatedDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surfaceOverlay,
        title: Row(
          children: [
            Icon(Icons.info_outline_rounded, color: AppTheme.accent),
            const SizedBox(width: 10),
            const Text(
              'AI Service Compatibility',
              style: TextStyle(color: Colors.white, fontSize: 18),
            ),
          ],
        ),
        content: const Text(
          'AIs like Claude and ChatGPT, as well as certain other services, may occasionally return an Error 406 or refuse connections while using OryvexVPN.\n\nThis happens because these services detect specific network parameters that they don\'t accept and recognize the program, causing them to block the connection. Your VPN is still connected and working normally.\n\nWe will try to fix this issue in the future.',
          style: TextStyle(color: AppTheme.textDim, height: 1.5, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close', style: TextStyle(color: AppTheme.textMuted)),
          ),
        ],
      ),
    );
  }

  // ── Mode selector ─────────────────────────────────────────────────
  Widget _buildModeSelector(VPNService vpn, bool active) {
    return AnimatedBuilder(
      animation: _entryController,
      builder: (context, child) {
        return FadeTransition(
          opacity: CurvedAnimation(
            parent: _entryController,
            curve: const Interval(0.3, 0.7, curve: Curves.easeOut),
          ),
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.1),
              end: Offset.zero,
            ).animate(CurvedAnimation(
              parent: _entryController,
              curve: const Interval(0.3, 0.7, curve: Curves.easeOutCubic),
            )),
            child: child,
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: AppTheme.containerDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  active ? Icons.lock : Icons.lock_open,
                  size: 14,
                  color: active ? AppTheme.accent : AppTheme.textSecondary,
                ),
                const SizedBox(width: 8),
                Text(
                  'CONNECTION MODE',
                  style: AppTheme.labelStyle.copyWith(
                    color: active ? AppTheme.accent : AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _buildModeChip(
                  label: 'WireGuard',
                  icon: Icons.shield,
                  isSelected: vpn.isWireGuardMode,
                  active: active,
                  onTap: () => vpn.setVpnMode(VpnMode.wireGuard),
                ),
                const SizedBox(width: 8),
                _buildModeChip(
                  label: 'Oryvex Core',
                  icon: Icons.bolt,
                  isSelected: vpn.isOryvexMode,
                  active: active,
                  recommended: true,
                  onTap: () {
                    if (!active) {
                      _showProtocolSelector(context, vpn);
                    }
                  },
                ),
              ],
            ),
            if (vpn.isOryvexMode) ...[
              const SizedBox(height: 8),
              _buildProtocolInfo(vpn),
            ],
          ],
        ),
      ),
    );
  }

  // ── Protocol selector dialog ──────────────────────────────────────
  void _showProtocolSelector(BuildContext context, VPNService vpn) {
    AppTheme.showAnimatedDialog(
      context: context,
      slideUp: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppTheme.borderLight),
        ),
        title: const Text(
          'Select Protocol',
          style: TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildProtocolOption(
              context: ctx,
              vpn: vpn,
              protocol: OryvexProtocol.auto,
              title: 'Auto',
              subtitle: 'Try all protocols (MASQUE → WireGuard → WARP)',
              icon: Icons.auto_awesome,
              color: AppTheme.purple,
            ),
            const SizedBox(height: 8),
            _buildProtocolOption(
              context: ctx,
              vpn: vpn,
              protocol: OryvexProtocol.masque,
              title: 'MASQUE',
              subtitle: 'Modern, QUIC/H3, best for DPI bypass',
              icon: Icons.speed,
              color: AppTheme.accent,
            ),
            const SizedBox(height: 8),
            _buildProtocolOption(
              context: ctx,
              vpn: vpn,
              protocol: OryvexProtocol.wireguard,
              title: 'WireGuard',
              subtitle: 'Classic, faster connection',
              icon: Icons.shield,
              color: AppTheme.primary,
            ),
            const SizedBox(height: 8),
            _buildProtocolOption(
              context: ctx,
              vpn: vpn,
              protocol: OryvexProtocol.warpinwarp,
              title: 'WARP-in-WARP',
              subtitle: 'Double tunnel, extra obfuscation',
              icon: Icons.hub,
              color: AppTheme.warning,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProtocolOption({
    required BuildContext context,
    required VPNService vpn,
    required OryvexProtocol protocol,
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
  }) {
    final isSelected = vpn.oryvexProtocol == protocol;
    return GestureDetector(
      onTap: () {
        vpn.setOryvexProtocol(protocol);
        vpn.setVpnMode(VpnMode.oryvexCore);
        Navigator.pop(context);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected ? color.withOpacity(0.15) : AppTheme.surfaceOverlay,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? color : AppTheme.borderLight,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: color.withOpacity(0.2),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(icon, size: 16, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: isSelected ? Colors.white : AppTheme.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected)
              Icon(Icons.check_circle, color: color, size: 18),
          ],
        ),
      ),
    );
  }

  Widget _buildProtocolInfo(VPNService vpn) {
    String protocolName;
    IconData protocolIcon;
    Color protocolColor;

    switch (vpn.oryvexProtocol) {
      case OryvexProtocol.masque:
        protocolName = 'MASQUE';
        protocolIcon = Icons.speed;
        protocolColor = AppTheme.accent;
        break;
      case OryvexProtocol.wireguard:
        protocolName = 'WireGuard';
        protocolIcon = Icons.shield;
        protocolColor = AppTheme.primary;
        break;
      case OryvexProtocol.warpinwarp:
        protocolName = 'WARP-in-WARP';
        protocolIcon = Icons.hub;
        protocolColor = AppTheme.warning;
        break;
      case OryvexProtocol.auto:
        protocolName = 'Auto';
        protocolIcon = Icons.auto_awesome;
        protocolColor = AppTheme.purple;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.surfaceOverlay,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(protocolIcon, size: 12, color: protocolColor),
          const SizedBox(width: 6),
          Text(
            protocolName,
            style: TextStyle(
              color: protocolColor,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModeChip({
    required String label,
    required IconData icon,
    required bool isSelected,
    required bool active,
    required VoidCallback onTap,
    bool recommended = false,
  }) {
    final color = isSelected ? AppTheme.accent : AppTheme.borderActive;
    final textColor = isSelected ? Colors.black : AppTheme.textSecondary;
    final iconColor = isSelected ? Colors.black : AppTheme.textSecondary;

    return Expanded(
      child: MouseRegion(
        cursor: active ? SystemMouseCursors.basic : SystemMouseCursors.click,
        child: GestureDetector(
          onTap: active ? null : onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: isSelected ? AppTheme.accent : AppTheme.border,
                width: isSelected ? 1.5 : 1,
              ),
              boxShadow: isSelected
                  ? AppTheme.glowShadow(AppTheme.accent, blurRadius: 8, opacity: 0.2)
                  : null,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 14, color: active && !isSelected ? Colors.white24 : iconColor),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: AppTheme.buttonLabelStyle.copyWith(
                    color: active && !isSelected ? Colors.white24 : textColor,
                  ),
                ),
                if (recommended && !isSelected) ...[
                  const SizedBox(width: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      color: AppTheme.warning.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: const Text(
                      'REC',
                      style: TextStyle(
                        fontSize: 7,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.warning,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Stats grid ────────────────────────────────────────────────────
  Widget _buildStatsGrid(VPNService vpn, {bool compact = false, double cardGap = 16}) {
    final s = vpn.stats;
    return AnimatedBuilder(
      animation: _entryController,
      builder: (context, child) {
        return FadeTransition(
          opacity: CurvedAnimation(
            parent: _entryController,
            curve: const Interval(0.5, 0.9, curve: Curves.easeOut),
          ),
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.1),
              end: Offset.zero,
            ).animate(CurvedAnimation(
              parent: _entryController,
              curve: const Interval(0.5, 0.9, curve: Curves.easeOutCubic),
            )),
            child: child,
          ),
        );
      },
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _buildBentoCard(
                  icon: Icons.timer_outlined,
                  title: 'DURATION',
                  value: vpn.connectedDuration,
                  color: AppTheme.purple,
                  compact: compact,
                ),
              ),
              SizedBox(width: cardGap),
              Expanded(
                child: _buildBentoCard(
                  icon: Icons.speed_rounded,
                  title: 'LATENCY',
                  value: s.ping > 0 ? '${s.ping} ms' : '—',
                  color: AppTheme.warning,
                  compact: compact,
                ),
              ),
            ],
          ),
          SizedBox(height: cardGap),
          Row(
            children: [
              Expanded(
                child: _buildBentoCard(
                  icon: Icons.arrow_downward,
                  title: 'DOWNLOAD',
                  value: _formatSpeed(s.downloadSpeed),
                  color: AppTheme.primary,
                  compact: compact,
                ),
              ),
              SizedBox(width: cardGap),
              Expanded(
                child: _buildBentoCard(
                  icon: Icons.arrow_upward,
                  title: 'UPLOAD',
                  value: _formatSpeed(s.uploadSpeed),
                  color: AppTheme.accent,
                  compact: compact,
                ),
              ),
            ],
          ),
          SizedBox(height: cardGap),
          _buildBentoCard(
            icon: Icons.public,
            title: 'IP ADDRESS',
            value: s.ipInfo.ip,
            color: AppTheme.purple,
            fullWidth: true,
            compact: compact,
          ),
        ],
      ),
    );
  }

  String _formatSpeed(double kbPerSec) {
    if (kbPerSec <= 0) return '—';
    if (kbPerSec < 1024) {
      return '${kbPerSec.toStringAsFixed(0)} KB/s';
    }
    return '${(kbPerSec / 1024).toStringAsFixed(1)} MB/s';
  }

  Widget _buildBentoCard({
    required IconData icon,
    required String title,
    required String value,
    required Color color,
    bool fullWidth = false,
    bool compact = false,
  }) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
        width: fullWidth ? double.infinity : null,
        padding: EdgeInsets.all(compact ? 14 : 20),
        decoration: fullWidth
            ? BoxDecoration(
                color: color.withOpacity(0.06),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: color.withOpacity(0.2)),
                boxShadow: AppTheme.glowShadow(color, blurRadius: 12, opacity: 0.1),
              )
            : AppTheme.glassDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(icon, size: 16, color: color),
                ),
                const SizedBox(width: 10),
                Text(
                  title,
                  style: AppTheme.labelStyle,
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              value,
              style: AppTheme.valueStyle,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Custom ring painter with glow & connecting sweep ───────────────
class _RingPainter extends CustomPainter {
  final Color color;
  final bool active;
  final double progress;
  final double glowIntensity;

  /// 0..1 current sweep tick of a rotating highlight while connecting.
  final double sweepTick;
  final bool sweepActive;

  _RingPainter({
    required this.color,
    required this.active,
    required this.progress,
    this.glowIntensity = 0.0,
    this.sweepTick = 0.0,
    this.sweepActive = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 2;
    const strokeWidth = 2.0;

    // Draw track ring
    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = AppTheme.border;
    canvas.drawCircle(center, radius, trackPaint);

    // Connecting: draw a rotating highlight sweep (a bright arc that
    // "comets" around the track) plus the progress arc.
    if (sweepActive) {
      // Progress arc — grows toward the stage progress.
      final sweepAngle = 2 * math.pi * progress.clamp(0.0, 1.0);
      final arcPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth * 1.5
        ..strokeCap = StrokeCap.round
        ..color = color.withOpacity(0.9);
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        sweepAngle,
        false,
        arcPaint,
      );

      // Rotating comet highlight.
      final cometPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth * 3
        ..strokeCap = StrokeCap.round
        ..color = color.withOpacity(0.55)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);
      final cometStart = -math.pi / 2 + 2 * math.pi * sweepTick - 1.2;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        cometStart,
        0.8,
        false,
        cometPaint,
      );
      return;
    }

    if (!active && progress == 0) return;

    // Draw glow layer (behind the arc)
    if (glowIntensity > 0) {
      final glowPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth * 4
        ..strokeCap = StrokeCap.round
        ..color = color.withOpacity(glowIntensity)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

      final start = -math.pi / 2;
      final sweep = 2 * math.pi * progress.clamp(0.0, 1.0);
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        start,
        sweep,
        false,
        glowPaint,
      );
    }

    // Draw main arc
    final arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth * 1.5
      ..strokeCap = StrokeCap.round
      ..color = color;

    final start = -math.pi / 2;
    final sweep = 2 * math.pi * progress.clamp(0.0, 1.0);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      start,
      sweep,
      false,
      arcPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.active != active ||
      oldDelegate.progress != progress ||
      oldDelegate.glowIntensity != glowIntensity ||
      oldDelegate.sweepTick != sweepTick ||
      oldDelegate.sweepActive != sweepActive;
}

// ── Drifting aurora glow background ────────────────────────────────
// Cheap radial-gradient blobs (no BackdropFilter — perf on Windows) that
// slowly drift to give the background a living, neon aurora feel.
class _AuroraBackground extends StatelessWidget {
  final Animation<double> animation;
  const _AuroraBackground({required this.animation});

  double _wave(double t, int phase) =>
      (math.sin(t * 2 * math.pi + phase * 1.7) + 1) / 2;

  Widget _blob(Color color, Alignment align, double size) => Align(
    alignment: align,
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color.withOpacity(0.12), color.withOpacity(0.0)],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final t = animation.value;
        return Stack(
          children: [
            _blob(
              AppTheme.accent,
              Alignment(-1.2 + 0.7 * _wave(t, 0), -1.2 + 0.5 * _wave(t, 1)),
              190,
            ),
            _blob(
              AppTheme.primary,
              Alignment(1.2 - 0.7 * _wave(t, 1), 1.2 - 0.6 * _wave(t, 0)),
              210,
            ),
            _blob(
              AppTheme.purple,
              Alignment(0.2 + 0.8 * _wave(t, 2), 0.6 - 0.8 * _wave(t, 3)),
              150,
            ),
          ],
        );
      },
    );
  }
}
