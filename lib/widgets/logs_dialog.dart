import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/oryvex_service.dart';
import '../services/xray_service.dart';
import '../services/vpn_service.dart';
import '../theme/app_theme.dart';

/// A single parsed log line.
/// Raw lines look like `[HH:mm:ss] ORYVEX: ...` / `[HH:mm:ss] XRAY: ...`.
class _LogEntry {
  final String raw;
  final String timestamp;
  final String? tag; // ORYVEX | XRAY | null
  final String level; // error | warn | success | info
  final String message;

  const _LogEntry({
    required this.raw,
    required this.timestamp,
    required this.level,
    required this.message,
    this.tag,
  });

  factory _LogEntry.parse(String raw) {
    String timestamp = '';
    String? tag;
    String level = 'info';
    String message = raw;

    final timeMatch =
        RegExp(r'^\[(\d{2}:\d{2}:\d{2})\]\s*(.*)$').firstMatch(raw);
    if (timeMatch != null) {
      timestamp = timeMatch.group(1)!;
      message = timeMatch.group(2)!;
    }

    final tagMatch = RegExp(r'^(ORYVEX|XRAY)\s*[:-]?\s*(.*)$', caseSensitive: false)
        .firstMatch(message);
    if (tagMatch != null) {
      tag = tagMatch.group(1)!.toUpperCase();
      message = tagMatch.group(2)!;
    }

    final upper = message.toUpperCase();
    if (upper.contains('ERROR') || upper.contains('EXCEPTION')) {
      level = 'error';
    } else if (upper.contains('WARN')) {
      level = 'warn';
    } else if (upper.contains('[+]') || upper.contains('SUCCESS')) {
      level = 'success';
    }

    return _LogEntry(
      raw: raw,
      timestamp: timestamp,
      tag: tag,
      level: level,
      message: message.trim(),
    );
  }
}

/// A responsive, real-time console for oryvex + xray core logs.
class LogsDialog extends StatefulWidget {
  const LogsDialog({super.key});

  @override
  State<LogsDialog> createState() => _LogsDialogState();
}

class _LogsDialogState extends State<LogsDialog> {
  final List<_LogEntry> _entries = [];
  final List<_LogEntry> _filtered = [];
  final ScrollController _scrollController = ScrollController();
  StreamSubscription<String>? _oryvexSubscription;
  StreamSubscription<String>? _xraySubscription;

  bool _autoScroll = true;
  bool _showSearch = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final recent = <String>[
      ...OryvexService.recentLogs,
      ...XrayService.recentLogs,
    ]..sort();
    _entries.addAll(recent.map(_LogEntry.parse));
    _applyFilter();

    _oryvexSubscription = OryvexService.logStream.listen(_addLog);
    _xraySubscription = XrayService.logStream.listen(_addLog);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom(instant: true);
    });
  }

  void _addLog(String line) {
    if (!mounted) return;
    setState(() {
      _entries.add(_LogEntry.parse(line));
      if (_entries.length > 800) _entries.removeAt(0);
      _applyFilter();
    });
    if (_autoScroll) _scrollToBottom();
  }

  @override
  void dispose() {
    _oryvexSubscription?.cancel();
    _xraySubscription?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _applyFilter() {
    _filtered.clear();
    if (_searchQuery.isEmpty) {
      _filtered.addAll(_entries);
      return;
    }
    final q = _searchQuery.toLowerCase();
    for (final e in _entries) {
      if (e.raw.toLowerCase().contains(q)) _filtered.add(e);
    }
  }

  void _scrollToBottom({bool instant = false}) {
    if (!_scrollController.hasClients) return;
    if (instant) {
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _toggleAutoScroll() {
    setState(() {
      _autoScroll = !_autoScroll;
      if (_autoScroll) _scrollToBottom();
    });
  }

  void _toggleSearch() {
    setState(() {
      _showSearch = !_showSearch;
      if (!_showSearch) {
        _searchQuery = '';
        _searchController.clear();
        _applyFilter();
      }
    });
  }

  void _onSearchChanged(String query) {
    setState(() {
      _searchQuery = query;
      _applyFilter();
    });
  }

  Color _levelColor(_LogEntry e) {
    switch (e.level) {
      case 'error':
        return AppTheme.errorLight;
      case 'warn':
        return AppTheme.warning;
      case 'success':
        return AppTheme.success;
      default:
        return AppTheme.textDim;
    }
  }

  Color? _tagColor(_LogEntry e) {
    if (e.tag == 'ORYVEX') return AppTheme.accent;
    if (e.tag == 'XRAY') return AppTheme.purple;
    return null;
  }

  // ── line widget ────────────────────────────────────────────────────
  Widget _buildLine(_LogEntry e) {
    final tagColor = _tagColor(e);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (e.tag != null && tagColor != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: tagColor.withOpacity(0.15),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: tagColor.withOpacity(0.4)),
              ),
              child: Text(
                e.tag!,
                style: TextStyle(
                  color: tagColor,
                  fontSize: 8,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                  fontFamily: 'Consolas',
                ),
              ),
            ),
            const SizedBox(width: 6),
          ],
          SizedBox(
            width: e.timestamp.isEmpty ? 0 : 58,
            child: Text(
              e.timestamp,
              style: const TextStyle(
                color: AppTheme.textTertiary,
                fontFamily: 'Consolas',
                fontSize: 10,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: SelectableText(
              e.message,
              style: TextStyle(
                color: _levelColor(e),
                fontFamily: 'Consolas',
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── header ────────────────────────────────────────────────────────
  Widget _buildHeader() {
    final vpn = context.watch<VPNService>();
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        border: const Border(bottom: BorderSide(color: AppTheme.borderLight)),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppTheme.accent.withOpacity(0.14),
            AppTheme.surface,
          ],
          stops: const [0.0, 0.45],
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              gradient: AppTheme.accentGradient,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.terminal_rounded, color: Colors.black, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Text(
                      'CORE LOGS',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (_autoScroll)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: AppTheme.error.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: AppTheme.error.withOpacity(0.5)),
                        ),
                        child: const Text(
                          'LIVE',
                          style: TextStyle(
                            color: AppTheme.error,
                            fontSize: 8,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1,
                          ),
                        ),
                      ),
                    if (_searchQuery.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Text(
                        '${_filtered.length} matches',
                        style: const TextStyle(
                          color: AppTheme.accent,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  vpn.isConnected
                      ? 'Connected · ${vpn.statusMessage}'
                      : vpn.isConnecting
                          ? vpn.statusMessage
                          : 'Console output from core processes',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close, color: AppTheme.textSecondary, size: 20),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            tooltip: 'Close',
          ),
        ],
      ),
    );
  }

  // ── list ───────────────────────────────────────────────────────────
  Widget _buildList() {
    if (_filtered.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _searchQuery.isNotEmpty ? Icons.search_off : Icons.terminal_rounded,
              color: AppTheme.textTertiary,
              size: 48,
            ),
            const SizedBox(height: 12),
            Text(
              _searchQuery.isNotEmpty
                  ? 'No logs match "$_searchQuery"'
                  : 'No logs yet. Connect to see core output.',
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      controller: _scrollController,
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      itemCount: _filtered.length,
      itemBuilder: (context, index) => _buildLine(_filtered[index]),
    );
  }

  // ── action chip ────────────────────────────────────────────────────
  Widget _actionChip({
    required IconData icon,
    required VoidCallback onTap,
    required String label,
    Color? color,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: (color ?? AppTheme.textSecondary).withOpacity(0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: (color ?? AppTheme.textSecondary).withOpacity(0.2),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color ?? AppTheme.textSecondary),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: color ?? AppTheme.textSecondary,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── action bar ─────────────────────────────────────────────────────
  Widget _buildActionBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppTheme.borderLight)),
      ),
      child: _showSearch
          ? TextField(
              controller: _searchController,
              autofocus: true,
              onChanged: _onSearchChanged,
              style: const TextStyle(color: Colors.white, fontSize: 13, fontFamily: 'Consolas'),
              decoration: InputDecoration(
                hintText: 'Search logs… (type to filter)',
                hintStyle: TextStyle(color: AppTheme.textTertiary),
                prefixIcon: const Icon(Icons.search, color: AppTheme.accent, size: 18),
                suffixIcon: IconButton(
                  onPressed: _toggleSearch,
                  icon: const Icon(Icons.close, color: AppTheme.textSecondary, size: 18),
                ),
                filled: true,
                fillColor: AppTheme.surfaceElevated,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppTheme.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppTheme.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppTheme.accent),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            )
          : Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _actionChip(
                  icon: Icons.copy_all_rounded,
                  label: 'Copy',
                  onTap: () {
                    final text = _filtered.map((e) => e.raw).join('\n');
                    Clipboard.setData(ClipboardData(text: text));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Logs copied to clipboard'),
                        duration: Duration(seconds: 2),
                        backgroundColor: AppTheme.surfaceOverlay,
                      ),
                    );
                  },
                ),
                _actionChip(
                  icon: Icons.delete_sweep_outlined,
                  label: 'Clear',
                  onTap: () {
                    setState(() {
                      _entries.clear();
                      _applyFilter();
                    });
                    OryvexService.clearLogs();
                    XrayService.clearLogs();
                  },
                ),
                _actionChip(
                  icon: _autoScroll
                      ? Icons.vertical_align_bottom
                      : Icons.sync_alt,
                  label: _autoScroll ? 'Auto' : 'Free',
                  color: _autoScroll ? AppTheme.accent : null,
                  onTap: _toggleAutoScroll,
                ),
                _actionChip(
                  icon: Icons.search,
                  label: 'Filter',
                  color: _showSearch ? AppTheme.accent : null,
                  onTap: _toggleSearch,
                ),
              ],
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final dialogW = math.min(720.0, screenSize.width * 0.92);
    final dialogH = math.min(640.0, screenSize.height * 0.85);

    return Dialog(
      backgroundColor: AppTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppTheme.borderLight),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: SizedBox(
        width: dialogW,
        height: dialogH,
        child: Column(
          children: [
            _buildHeader(),
            if (_showSearch)
              Container(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: TextField(
                  controller: _searchController,
                  autofocus: true,
                  onChanged: _onSearchChanged,
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontFamily: 'Consolas'),
                  decoration: InputDecoration(
                    hintText: 'Search logs…',
                    hintStyle: TextStyle(color: AppTheme.textTertiary),
                    prefixIcon: const Icon(Icons.search, color: AppTheme.accent, size: 18),
                    suffixIcon: IconButton(
                      onPressed: _toggleSearch,
                      icon: const Icon(Icons.close, color: AppTheme.textSecondary, size: 18),
                    ),
                    filled: true,
                    fillColor: AppTheme.surfaceElevated,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: AppTheme.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: AppTheme.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: AppTheme.accent),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                ),
              ),
            Expanded(child: _buildList()),
            _buildActionBar(),
          ],
        ),
      ),
    );
  }
}