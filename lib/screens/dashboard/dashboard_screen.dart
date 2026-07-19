import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../models/app_state.dart';
import '../../models/server_model.dart';
import '../../services/process_manager.dart';
import '../../services/debug_logger.dart';
import '../../services/tunnel_service.dart';
import '../../services/drive_service.dart';
import '../menu/server_list_drawer.dart';
import '../setup_wizard/setup_wizard.dart';
import '../settings/settings_screen.dart';
import 'server_settings_screen.dart';
import '../../services/stats_service.dart';
import 'plugin_manager_screen.dart';
import '../../services/java_downloader.dart';
import '../setup_wizard/drive_browser_screen.dart';
import '../../services/platform_service.dart';
import '../../services/console_log_service.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final ServerProcess _server = ServerProcess();
  final TunnelService _tunnel = TunnelService();
  final DriveService _drive = DriveService();
  final StatsService _stats = StatsService();

  bool _userScrolledUp = false;
  bool _showScrollDown = false;
  bool _programmaticScroll = false;

  final ConsoleLogService _consoleLog =
      ConsoleLogService();

  final List<String> _logs = [];
  final List<String> _tunnelLogs = [];

  final List<String> _pendingLogLines = [];
  Timer? _logFlushTimer;
  static const int _maxLogLines = 1000;

  final TextEditingController _commandController = TextEditingController();

  final ScrollController _consoleScrollController = ScrollController();
  ServerStats _currentStats = const ServerStats();

  // Active server state
  ServerModel? _activeServer;
  String _serverPath = r'/home/unbinding/mc-test';
  int _ramMb = 1024;
  bool _serverStarting = false;

  // Tunnel
  TunnelStatus _tunnelStatus = TunnelStatus.stopped;
  String _tunnelAddress = '';
  String _playitBinaryPath = '/home/unbinding/playit';

  // Drive
  bool _driveSignedIn = false;
  bool _backingUp = false;
  Timer? _autoBackupTimer;
  int _autoBackupIntervalMinutes = 30;
  String _backupFolderName = 'PocketServer Backups';
  int _keepCount = 5;
  bool _backupOnStop = true;
  String _backupPath = r'\\wsl$\Ubuntu\home\unbinding\mc-test';

  // Uptime
  Duration _uptime = Duration.zero;
  Timer? _uptimeTimer;
  DateTime? _serverStartTime;

  @override
  void initState() {
    super.initState();
    // 1. Mark this callback as 'async'
    WidgetsBinding.instance.addPostFrameCallback((_) async { 
      // Set default server path for platform
      final serversBase = await PlatformService.getServersPath();
    
      // 2. Always check if (mounted) before calling setState after an 'await'
      if (!mounted) return; 
      setState(() => _serverPath = '$serversBase/default');

      _setupConsoleScrollListener();

      _stats.stats.listen((s) {
        if (mounted) setState(() => _currentStats = s);
      });

      _server.output.listen((line) {
        if (mounted) {
          DebugLogger.log(line, tag: 'MC');
          _parseServerOutput(line);
          _consoleLog.write(line);
          _appendLog(line);
        }
      });

      _tunnel.status.listen((status) {
        if (mounted) {
          setState(() {
            _tunnelStatus = status;
            if (status == TunnelStatus.connected &&
                _tunnel.tunnelAddress != null) {
              _tunnelAddress = _tunnel.tunnelAddress!;
            }
          });
        }
      });

      _tunnel.output.listen((line) {
        if (mounted) _appendLog(line, tunnel: true);
      });

      _drive.status.listen((msg) {
        if (mounted) _appendLog(msg);
      });

      // 3. Since we are inside an async callback, context might be stale
      // 'context.read' is usually okay here, but a safety check doesn't hurt
      final appState = context.read<AppState>();
      if (appState.servers.isEmpty) {
        _showNewServerOptions();
      } else if (appState.activeServer != null) {
        _loadServer(appState.activeServer!);
      }
    });
  }

    void _setupConsoleScrollListener() {
    _consoleScrollController.addListener(() {
      // Ignore notifications caused by our own jumpTo/animateTo calls —
      // otherwise auto-scrolling to the bottom fires this exact same
      // listener and can falsely flag "user scrolled up", which then
      // silently blocks all future auto-scrolling.
      if (_programmaticScroll) return;
      if (!_consoleScrollController.hasClients) return;
      final pos = _consoleScrollController.position;
      final atBottom =
          pos.pixels >= pos.maxScrollExtent - 100;
      if (mounted) {
        setState(() {
          _userScrolledUp = !atBottom;
          _showScrollDown = !atBottom;
        });
      }
    });
  }

  Future<void> _scrollConsoleToBottom({bool force = false, bool animate = false}) async {
    if (!force && _userScrolledUp) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !_consoleScrollController.hasClients) return;
    final target = _consoleScrollController.position.maxScrollExtent;
    _programmaticScroll = true;
    if (animate) {
      await _consoleScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    } else {
      _consoleScrollController.jumpTo(target);
    }
    _programmaticScroll = false;
    if (mounted) {
      setState(() {
        _userScrolledUp = false;
        _showScrollDown = false;
      });
    }
  }

  void _parseServerOutput(String line) {
    // Players count response from /list command
    final playerMatch = RegExp(
      r'There are (\d+) of a max of (\d+) players',
    ).firstMatch(line);
    if (playerMatch != null) {
      _stats.updateFromServerOutput(
        playersOnline: int.parse(playerMatch.group(1)!),
        maxPlayers: int.parse(playerMatch.group(2)!),
      );
    }

    // TPS — Paper/Spigot outputs e.g.:
    //   "TPS from last 1m, 5m, 15m: 20.0, 20.0, 20.0"
    final tpsMatch = RegExp(
      r'TPS from last (?:\d+m[,\s]*)+:\s*([\d.]+)',
    ).firstMatch(line);
    if (tpsMatch != null) {
      final tps = double.tryParse(tpsMatch.group(1)!) ?? 20.0;
      _stats.updateFromServerOutput(tps: tps.clamp(0.0, 20.0));
    }

    // Vanilla doesn't report TPS — reset to N/A (null-like sentinel 0)
    // when server just started so we don't show stale 20.0.
    // We detect "Done" to know the server is freshly up.
    if (line.contains('Done') && line.contains('For help, type')) {
      _serverStartTime = DateTime.now();
      _startUptimeTimer();
      // Reset TPS to --  for vanilla (Paper will update it via /tps polling)
      if (_activeServer?.serverType == ServerType.vanilla) {
        _stats.updateFromServerOutput(tps: -1); // sentinel = show '--'
      }
      final versionMatch =
          RegExp(r'Starting minecraft server version ([\d.]+)')
              .firstMatch(line);
      if (versionMatch != null) {
        _stats.updateFromServerOutput(version: versionMatch.group(1));
      }
    }

    // Players joining/leaving
    if (line.contains('joined the game')) {
      _stats.updateFromServerOutput(
          playersOnline: _currentStats.playersOnline + 1);
    }
    if (line.contains('left the game')) {
      _stats.updateFromServerOutput(
        playersOnline:
            (_currentStats.playersOnline - 1).clamp(0, 999),
      );
    }
  }
  void _openPluginManager() {
    if (_activeServer == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PluginManagerScreen(
          server: _activeServer!,
          onSaved: (updated) async {
            final appState = context.read<AppState>();
            await appState.updateServer(updated);
            _loadServer(updated);
          },
        ),
      ),
    );
  }
  void _startUptimeTimer() {
    _uptimeTimer?.cancel();
    _uptimeTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_serverStartTime != null && mounted) {
        final uptime = DateTime.now().difference(_serverStartTime!);
        setState(() => _uptime = uptime);
        _stats.updateFromServerOutput(uptime: uptime);
      }
    });
  }

  String _formatUptime(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  void _loadServer(ServerModel server) async {
    final nativePath =
        await PlatformService.toNativePath(server.path);
    setState(() {
      _activeServer = server;
      _serverPath = server.path;
      _ramMb = server.ramMb;
      _backupPath = nativePath;
      // Clear logs when switching servers
      _logs.clear();
    });

    // Load existing console log for this server
    _loadExistingLog(server.path);
  }

  Future<void> _loadExistingLog(
      String serverPath) async {
    try {
      final nativePath =
          await PlatformService.toNativePath(serverPath);
      final logFile = File(Platform.isWindows
          ? '$nativePath\\logs\\console.log'
          : '$nativePath/logs/console.log');

      if (await logFile.exists()) {
        final content = await logFile.readAsString();
        final lines = content
            .split('\n')
            .where((l) => l.isNotEmpty)
            .toList();

        if (mounted) {
          setState(() {
            _logs.addAll(lines);
          });
          // Scroll to bottom after loading
          _scrollConsoleToBottom(force: true);
        }
      }
    } catch (_) {}
  }
  void _appendLog(String line, {bool tunnel = false}) {
    _pendingLogLines.add(line);
    if (tunnel) _tunnelLogs.add(line);
    _logFlushTimer ??= Timer(const Duration(milliseconds: 120), () {
      _logFlushTimer = null;
      if (!mounted) return;
      setState(() {
        _logs.addAll(_pendingLogLines);
        _pendingLogLines.clear();
        if (_logs.length > _maxLogLines) {
          _logs.removeRange(0, _logs.length - _maxLogLines);
        }
      });
      _scrollConsoleToBottom();
    });
  }

  // ─── Server control ────────────────────────────────────────
  Future<void> _toggleServer() async {
    if (_serverStarting) return;
    if (_server.isRunning) {
      setState(() => _logs.add('[Stopping server...]'));
      await _server.stopServer();
      await _consoleLog.close();
      _uptimeTimer?.cancel();
      _stats.stop();
      setState(() {
        _uptime = Duration.zero;
        _serverStartTime = null;
      });
      if (_backupOnStop && _driveSignedIn) {
        setState(() => _logs.add('[Drive] Auto backup on stop...'));
        await _runBackup();
      }
      if (_activeServer != null) {
        if (_activeServer != null && mounted) {
        await context.read<AppState>().updateLastPlayed(_activeServer!.id);
      }
      }
    } else {
      setState(() {
        _serverStarting = true;
        _logs.add('[Starting server...]');
      });
      final ok = await _server.startServer(
        serverPath: _serverPath,
        javaPath: '',
        ramMb: _ramMb,
        version: _activeServer?.version ?? '1.20.4',
        onStatus: (msg) {
          if (mounted) _appendLog(msg);
        },
        properties: _activeServer?.properties,
        serverType: _activeServer?.serverType.name ?? 'vanilla',
      );
      if (ok) {
        _stats.start(
          serverPath: _serverPath,
          onPollTick: () {
            _server.sendCommand('list');
            // Paper supports /tps; for vanilla this outputs nothing useful
            // but is harmless
            if (_activeServer?.serverType == ServerType.paper) {
              _server.sendCommand('tps');
            }
          },
        );
        await _consoleLog.init(_serverPath);
      }
      setState(() => _serverStarting = false);
      if (!ok) setState(() => _logs.add('[Failed to start]'));
    }
    setState(() {});
  }

  void _sendCommand() {
    final cmd = _commandController.text.trim();
    if (cmd.isEmpty) return;
    _server.sendCommand(cmd);
    setState(() => _logs.add('> $cmd'));
    _commandController.clear();
  }

  // ─── Tunnel ────────────────────────────────────────────────
  Future<void> _toggleTunnel() async {
    if (_tunnel.isRunning) {
      await _tunnel.stop();
    } else {
      await _tunnel.start(playitBinaryPath: _playitBinaryPath);
    }
    setState(() {});
  }

  // ─── Drive ─────────────────────────────────────────────────
  Future<void> _toggleDriveSignIn() async {
    if (_driveSignedIn) {
      await _drive.signOut();
      setState(() => _driveSignedIn = false);
      _autoBackupTimer?.cancel();
    } else {
      final ok = await _drive.signIn();
      setState(() => _driveSignedIn = ok);
      if (ok) {
        setState(() =>
            _logs.add('[Drive] Signed in as ${_drive.userEmail}'));
        _startAutoBackup();
      }
    }
  }

  void _startAutoBackup() {
    _autoBackupTimer?.cancel();
    _autoBackupTimer = Timer.periodic(
      Duration(minutes: _autoBackupIntervalMinutes),
      (_) => _runBackup(),
    );
  }

  Future<void> _runBackup() async {
    if (_backingUp) return;
    setState(() => _backingUp = true);
    final worldName = _activeServer?.name
            .toLowerCase()
            .replaceAll(RegExp(r'[^a-z0-9]'), '_') ??
        'world';
    final ok = await _drive.backup(
      serverPath: _backupPath,
      folderName: _backupFolderName,
      keepCount: _keepCount,
      worldName: worldName,
    );
    setState(() {
      _backingUp = false;
      _logs.add(ok ? '[Drive] Backup complete!' : '[Drive] Backup failed');
    });
  }

  Future<void> _showBackupSettings() async {
    final folderController =
        TextEditingController(text: _backupFolderName);
    final intervalController =
        TextEditingController(text: _autoBackupIntervalMinutes.toString());

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Backup Settings'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Google Drive folder name',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 4),
            TextField(
              controller: folderController,
              decoration: InputDecoration(
                filled: true,
                fillColor: const Color(0xFF0D0D0D),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text('Auto backup interval (minutes)',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 4),
            TextField(
              controller: intervalController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                filled: true,
                fillColor: const Color(0xFF0D0D0D),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text('Backups to keep',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            StatefulBuilder(
              builder: (ctx, setLocal) => Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: _keepCount.toDouble(),
                      min: 1,
                      max: 20,
                      divisions: 19,
                      activeColor: const Color(0xFF00C853),
                      onChanged: (val) {
                        setLocal(() {});
                        setState(() => _keepCount = val.round());
                      },
                    ),
                  ),
                  Text('$_keepCount',
                      style: const TextStyle(
                          color: Color(0xFF00C853))),
                ],
              ),
            ),
            StatefulBuilder(
              builder: (ctx, setLocal) => SwitchListTile(
                value: _backupOnStop,
                onChanged: (val) {
                  setLocal(() {});
                  setState(() => _backupOnStop = val);
                },
                activeThumbColor: const Color(0xFF00C853),
                title: const Text('Backup on server stop',
                    style: TextStyle(fontSize: 13)),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel',
                style: TextStyle(color: Colors.grey)),
          ),
          FilledButton(
            onPressed: () {
              setState(() {
                _backupFolderName =
                    folderController.text.trim().isEmpty
                        ? 'PocketServer Backups'
                        : folderController.text.trim();
                _autoBackupIntervalMinutes =
                    int.tryParse(intervalController.text) ?? 30;
              });
              if (_driveSignedIn) _startAutoBackup();
              Navigator.pop(ctx);
            },
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF00C853),
              foregroundColor: Colors.black,
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  // ─── New server options ────────────────────────────────────
  void _showNewServerOptions() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Add Server'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  SetupWizard.show(
                    context,
                    onComplete: (server) async {
                      final appState = context.read<AppState>();
                      await appState.addServer(server);
                      await appState.setActiveServer(server);
                      _loadServer(server);
                    },
                  );
                },
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Create from scratch'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF00C853),
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _importFromDrive();
                },
                icon: const Icon(Icons.cloud_download, size: 18),
                label: const Text('Restore from Google Drive'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.blue,
                  side: const BorderSide(color: Colors.blue),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _importFromDrive() async {
    if (!_driveSignedIn) {
      final ok = await _drive.signIn();
      if (!ok) return;
      setState(() => _driveSignedIn = true);
    }

    if (!mounted) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DriveBrowserScreen(
          driveService: _drive,
          onImported: (server) {
            _loadServer(server);
            setState(() =>
                _logs.add('[Drive] Server imported: ${server.name}'));
          },
        ),
      ),
    );
  }

  // ─── Edit server ───────────────────────────────────────────
  void _editServer(ServerModel server) {
    SetupWizard.show(
      context,
      existingServer: server,
      onComplete: (updated) async {
        final appState = context.read<AppState>();
        await appState.updateServer(updated);
        if (_activeServer?.id == updated.id) {
          _loadServer(updated);
        }
      },
    );
  }

  // ─── Settings ──────────────────────────────────────────────
  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          driveService: _drive,
          driveSignedIn: _driveSignedIn,
          driveEmail: _drive.userEmail,
          onDriveSignOut: () async {
            await _toggleDriveSignIn();
            if (mounted) Navigator.pop(context);
          },
          onDriveSignIn: () async {
            await _toggleDriveSignIn();
            if (mounted) Navigator.pop(context);
          },
          playitBinaryPath: _playitBinaryPath,
          onPlayitPathChanged: (p) =>
              setState(() => _playitBinaryPath = p),
          tunnelAddress: _tunnelAddress,
          onTunnelAddressChanged: (a) =>
              setState(() => _tunnelAddress = a),
          tunnelStatus: _tunnelStatus.name,
          tunnelLogs: _tunnelLogs,
        ),
      ),
    );
  }

  void _openServerSettings() {
    if (_activeServer == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ServerSettingsScreen(
          server: _activeServer!,
          serverIsRunning: _server.isRunning,
          onSendCommand: (cmd) => _server.sendCommand(cmd),
          onSaved: (updated) async {
            final appState = context.read<AppState>();
            await appState.updateServer(updated);
            _loadServer(updated);
          },
        ),
      ),
    );
  }
  Future<void> _openLogFile() async {
    if (_activeServer == null) return;

    final logPath = Platform.isWindows
        ? '${_activeServer!.path}\\logs\\console.log'
        : '${_activeServer!.path}/logs/console.log';

    final file = File(logPath);
    if (!await file.exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'No log yet — start the server first'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    if (Platform.isWindows) {
      await Process.run(
        'cmd',
        ['/c', 'start', '', logPath],
        runInShell: true,
      );
    } else if (Platform.isAndroid) {
      final content = await file.readAsString();
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1A1A1A),
            title: const Text('console.log'),
            content: SizedBox(
              width: double.maxFinite,
              height: 400,
              child: SingleChildScrollView(
                child: SelectableText(
                  content,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: Color(0xFF00C853),
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Clipboard.setData(
                      ClipboardData(text: content));
                  Navigator.pop(ctx);
                },
                child: const Text('Copy',
                    style: TextStyle(
                        color: Color(0xFF00C853))),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close',
                    style:
                        TextStyle(color: Colors.grey)),
              ),
            ],
          ),
        );
      }
    }
  }
  @override
  void dispose() {
    _consoleScrollController.dispose(); 
    _server.dispose();
    _tunnel.dispose();
    _drive.dispose();
    _stats.dispose();
    _commandController.dispose();
    _autoBackupTimer?.cancel();
    _uptimeTimer?.cancel();
    _consoleLog.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isPhone = size.width < 600;
    final tunnelAddress = _tunnelAddress.isNotEmpty
        ? _tunnelAddress
        : _tunnel.tunnelAddress ?? '';

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _activeServer?.name ?? 'PocketServer',
          style: TextStyle(
              fontSize: isPhone ? 15 : 18),
        ),
        actions: _buildAppBarActions(isPhone),
      ),
      drawer: ServerListDrawer(
        activeServerId: _activeServer?.id,
        onServerSelected: (server) {
          context.read<AppState>().setActiveServer(server);
          _loadServer(server);
        },
        onAddServer: () {
          Navigator.pop(context);
          _showNewServerOptions();
        },
        onEditServer: _editServer,
        onDeleteServer:
            (server, {bool deleteFiles = false}) async {
          final appState = context.read<AppState>();
          if (deleteFiles) {
            try {
              final dir = Directory(server.path);
              if (await dir.exists()) {
                await dir.delete(recursive: true);
              }
            } catch (e) {
              // If Dart delete fails try shell
              await PlatformService.runCommand(
                  'rm -rf "${server.path.replaceAll('\\', '/')}"');
            }
          }
          await appState.removeServer(server.id);
          final remaining = appState.servers;
          if (_activeServer?.id == server.id) {
            if (remaining.isNotEmpty) {
              _loadServer(remaining.first);
            } else {
              setState(() => _activeServer = null);
            }
          }
        },
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          // ── Top panel: stats, RAM, everything that isn't the console ──
          // No scroll wrapper and no fixed height — all stat cards should
          // just be visible at once, and the console below adjusts to
          // whatever space is left.
          final statsPanel = _buildStatsDashboard(constraints.maxWidth);

          // ── Console header (fixed, sits above the scrolling log list) ──
          final consoleHeader = Container(
            color: const Color(0xFF1A1A1A),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.terminal, size: 16, color: Colors.grey),
                const SizedBox(width: 8),
                const Text('Console', style: TextStyle(fontSize: 13, color: Colors.grey)),
                const Spacer(),
                GestureDetector(
                  onTap: () {
                    if (_logs.isEmpty) return;
                    Clipboard.setData(ClipboardData(text: _logs.join('\n')));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Console copied to clipboard'),
                      duration: Duration(seconds: 2),
                    ));
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.copy_all, size: 12, color: Colors.grey),
                        SizedBox(width: 4),
                        Text('Copy all', style: TextStyle(fontSize: 11, color: Colors.grey)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (_activeServer != null)
                  GestureDetector(
                    onTap: _openLogFile,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.open_in_new, size: 12, color: Colors.grey),
                          SizedBox(width: 4),
                          Text('Open log', style: TextStyle(fontSize: 11, color: Colors.grey)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          );

          // ── Scrolling log list — owns its own controller/scrollbar ──
          final consoleList = Scrollbar(
            controller: _consoleScrollController,
            thumbVisibility: true,
            child: SelectionArea(
              child: ListView.builder(
                controller: _consoleScrollController,
                padding: const EdgeInsets.all(12),
                itemCount: _logs.length,
                itemBuilder: (_, i) => Container(
                  color: const Color(0xFF0D0D0D),
                  child: Text(
                    _logs[i],
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: Color(0xFF00C853),
                    ),
                  ),
                ),
              ),
            ),
          );

          // ── Command bar — pinned below the console, never scrolls away ──
          final commandBar = Container(
            color: const Color(0xFF1A1A1A),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                const Text('> ', style: TextStyle(color: Color(0xFF00C853), fontFamily: 'monospace', fontSize: 14)),
                Expanded(
                  child: TextField(
                    controller: _commandController,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                    decoration: const InputDecoration(hintText: 'Enter server command...', border: InputBorder.none),
                    onSubmitted: (_) => _sendCommand(),
                  ),
                ),
                IconButton(icon: const Icon(Icons.send), onPressed: _sendCommand),
              ],
            ),
          );

          // ── Console column: header + scrolling list (with its own
          // scroll-to-top/bottom buttons) + pinned command bar ──
          final consoleColumn = Column(
            children: [
              consoleHeader,
              Expanded(
                child: Stack(
                  alignment: Alignment.bottomCenter,
                  children: [
                    consoleList,
                    Positioned(
                      top: 8,
                      right: 16,
                      child: FloatingActionButton.small(
                        heroTag: 'console_scroll_top',
                        onPressed: () => _consoleScrollController.animateTo(
                            0,
                            duration: const Duration(milliseconds: 400),
                            curve: Curves.easeOut),
                        backgroundColor: const Color(0xFF1A1A1A),
                        child: const Icon(Icons.keyboard_arrow_up, color: Colors.grey),
                      ),
                    ),
                    if (_showScrollDown)
                      Positioned(
                        bottom: 12,
                        child: GestureDetector(
                          onTap: () {
                            setState(() {
                              _userScrolledUp = false;
                              _showScrollDown = false;
                            });
                            _scrollConsoleToBottom(
                                force: true, animate: true);
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF00C853),
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 4)],
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.keyboard_arrow_down, color: Colors.black, size: 20),
                                SizedBox(width: 4),
                                Text("Jump to Bottom", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 12)),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              commandBar,
            ],
          );

          // Stats always on top (own scroll if it overflows), console
          // always fills the rest of the space below it — the console's
          // size stays fixed as logs come in; only its internal list
          // scrolls, and the command bar stays pinned under it.
          return Column(
            children: [
              statsPanel,
              const Divider(height: 1, color: Color(0xFF2A2A2A)),
              Expanded(child: consoleColumn),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _buildAppBarActions(bool isPhone) {
    final tunnelAddress = _tunnelAddress.isNotEmpty
        ? _tunnelAddress
        : _tunnel.tunnelAddress ?? '';

    if (isPhone) {
      // Phone: show overflow menu for most actions
      return [
        TextButton.icon(
          onPressed: _toggleTunnel,
          icon: Icon(
            _tunnelStatus == TunnelStatus.connected
                ? Icons.wifi
                : _tunnelStatus ==
                        TunnelStatus.connecting
                    ? Icons.wifi_find
                    : Icons.wifi_off,
            size: 16,
            color: _tunnelStatus ==
                    TunnelStatus.connected
                ? Colors.green
                : _tunnelStatus ==
                        TunnelStatus.connecting
                    ? Colors.orange
                    : Colors.grey,
          ),
          label: Text(
            _tunnelStatus == TunnelStatus.connected
                ? 'On'
                : _tunnelStatus ==
                        TunnelStatus.connecting
                    ? '...'
                    : 'Off',
            style: TextStyle(
              fontSize: 11,
              color: _tunnelStatus ==
                      TunnelStatus.connected
                  ? Colors.green
                  : Colors.grey,
            ),
          ),
        ),
        Padding(
          padding:
              const EdgeInsets.only(right: 8, left: 4),
          child: FilledButton(
            onPressed: _serverStarting
                ? null
                : _toggleServer,
            style: FilledButton.styleFrom(
              backgroundColor: _serverStarting
                  ? Colors.grey[700]
                  : _server.isRunning
                      ? Colors.red[700]
                      : Colors.green[700],
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 8),
              minimumSize: Size.zero,
            ),
            child: _serverStarting
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.black,
                    ),
                  )
                : Icon(
                    _server.isRunning
                        ? Icons.stop
                        : Icons.play_arrow,
                    size: 18,
                  ),
          ),
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          onSelected: (val) {
            switch (val) {
              case 'settings':
                _openSettings();
                break;
              case 'server_settings':
                _openServerSettings();
                break;
              case 'plugins':
                _openPluginManager();
                break;
              case 'backup':
                _driveSignedIn
                    ? _runBackup()
                    : _toggleDriveSignIn();
                break;
              case 'backup_settings':
                _showBackupSettings();
                break;
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(
              value: 'settings',
              child: ListTile(
                leading: Icon(Icons.settings, size: 18),
                title: Text('App settings',
                    style: TextStyle(fontSize: 13)),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            if (_activeServer != null)
              const PopupMenuItem(
                value: 'server_settings',
                child: ListTile(
                  leading: Icon(Icons.tune, size: 18),
                  title: Text('Server settings',
                      style: TextStyle(fontSize: 13)),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            if (_activeServer != null)
              const PopupMenuItem(
                value: 'plugins',
                child: ListTile(
                  leading:
                      Icon(Icons.extension, size: 18),
                  title: Text('Mods/Plugins',
                      style: TextStyle(fontSize: 13)),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            PopupMenuItem(
              value: 'backup',
              child: ListTile(
                leading: Icon(
                  _driveSignedIn
                      ? Icons.backup
                      : Icons.cloud_off,
                  size: 18,
                ),
                title: Text(
                  _driveSignedIn
                      ? 'Backup now'
                      : 'Connect Drive',
                  style: const TextStyle(fontSize: 13),
                ),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            if (_driveSignedIn)
              const PopupMenuItem(
                value: 'backup_settings',
                child: ListTile(
                  leading: Icon(
                      Icons.settings_backup_restore,
                      size: 18),
                  title: Text('Backup settings',
                      style: TextStyle(fontSize: 13)),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
          ],
        ),
      ];
    }

    // Desktop: show all actions
    return [
      IconButton(
        onPressed: _openSettings,
        icon: const Icon(Icons.settings, size: 20),
        tooltip: 'App settings',
      ),
      if (_activeServer != null)
        IconButton(
          onPressed: _openServerSettings,
          icon: const Icon(Icons.tune, size: 20),
          tooltip: 'Server settings',
        ),
      if (_activeServer != null)
        IconButton(
          onPressed: _openPluginManager,
          icon: const Icon(Icons.extension, size: 20),
          tooltip: _activeServer?.serverType ==
                  ServerType.paper
              ? 'Plugin & datapack manager'
              : 'Mod & datapack manager',
        ),
      if (_driveSignedIn)
        IconButton(
          onPressed: _showBackupSettings,
          icon: const Icon(
              Icons.settings_backup_restore, size: 20),
          tooltip: 'Backup settings',
          color: Colors.blue,
        ),
      IconButton(
        onPressed: _backingUp
            ? null
            : () async {
                if (!_driveSignedIn) {
                  await _toggleDriveSignIn();
                } else {
                  await _runBackup();
                }
              },
        icon: _backingUp
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2),
              )
            : Icon(
                _driveSignedIn
                    ? Icons.backup
                    : Icons.cloud_off,
                size: 20,
                color: _driveSignedIn
                    ? Colors.blue
                    : Colors.grey,
              ),
        tooltip: _driveSignedIn
            ? 'Backup now'
            : 'Connect Google Drive',
      ),
      TextButton.icon(
        onPressed: _toggleTunnel,
        icon: Icon(
          _tunnelStatus == TunnelStatus.connected
              ? Icons.wifi
              : _tunnelStatus ==
                      TunnelStatus.connecting
                  ? Icons.wifi_find
                  : Icons.wifi_off,
          size: 18,
          color: _tunnelStatus ==
                  TunnelStatus.connected
              ? Colors.green
              : _tunnelStatus ==
                      TunnelStatus.connecting
                  ? Colors.orange
                  : Colors.grey,
        ),
        label: Text(
          _tunnelStatus == TunnelStatus.connected
              ? (tunnelAddress.length > 20
                  ? tunnelAddress.substring(0, 20) +
                      '...'
                  : tunnelAddress)
              : _tunnelStatus ==
                      TunnelStatus.connecting
                  ? 'Connecting...'
                  : 'Tunnel Off',
          style: TextStyle(
            fontSize: 12,
            color: _tunnelStatus ==
                    TunnelStatus.connected
                ? Colors.green
                : _tunnelStatus ==
                        TunnelStatus.connecting
                    ? Colors.orange
                    : Colors.grey,
          ),
        ),
      ),
      Padding(
        padding:
            const EdgeInsets.only(right: 16, left: 4),
        child: FilledButton.icon(
          onPressed:
              _serverStarting ? null : _toggleServer,
          icon: _serverStarting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.black,
                  ),
                )
              : Icon(_server.isRunning
                  ? Icons.stop
                  : Icons.play_arrow),
          label: Text(_serverStarting
              ? 'Starting...'
              : _server.isRunning
                  ? 'Stop'
                  : 'Start'),
          style: FilledButton.styleFrom(
            backgroundColor: _serverStarting
                ? Colors.grey[700]
                : _server.isRunning
                    ? Colors.red[700]
                    : Colors.green[700],
          ),
        ),
      ),
    ];
  }

  Widget _buildStatsDashboard(double width) {
    final s = _currentStats;
    final isOnline = _server.isRunning;
    final isPhone = width < 600;
    // There are 8 stat cards — only use column counts that divide evenly
    // into 8 (2, 4, 8) so every row is full and no row looks lopsided.
    final crossAxisCount = width < 500
        ? 2 // 4 rows of 2
        : width < 1000
            ? 4 // 2 rows of 4
            : 8; // 1 row of 8
    final cardAspect = crossAxisCount == 2
        ? 2.1
        : crossAxisCount == 4
            ? 1.5
            : 1.7;

    Color tpsColor() {
      if (s.tps >= 18) return Colors.green;
      if (s.tps >= 12) return Colors.orange;
      return Colors.red;
    }

    Color packetColor() {
      if (s.packetLoss == 0) return Colors.green;
      if (s.packetLoss < 5) return Colors.orange;
      return Colors.red;
    }

    String formatRam(int mb) {
      if (mb < 1024) return '${mb}MB';
      return '${(mb / 1024).toStringAsFixed(1)}GB';
    }

    String formatSize(int mb) {
      if (mb < 1024) return '${mb}MB';
      return '${(mb / 1024).toStringAsFixed(2)}GB';
    }

    final tunnelAddress = _tunnelAddress.isNotEmpty
        ? _tunnelAddress
        : _tunnel.tunnelAddress ?? '';

    return Container(
      color: const Color(0xFF111111),
      padding: EdgeInsets.all(isPhone ? 10 : 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status row
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment:
                WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isOnline
                          ? Colors.green
                          : Colors.grey,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    isOnline ? 'Online' : 'Offline',
                    style: TextStyle(
                      fontSize: 13,
                      color: isOnline
                          ? Colors.green
                          : Colors.grey,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              if (isOnline && tunnelAddress.isNotEmpty)
                GestureDetector(
                  onTap: () {
                    Clipboard.setData(ClipboardData(
                        text: tunnelAddress));
                    ScaffoldMessenger.of(context)
                        .showSnackBar(
                      const SnackBar(
                        content:
                            Text('Address copied!'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.green
                          .withValues(alpha: 0.1),
                      borderRadius:
                          BorderRadius.circular(6),
                      border: Border.all(
                          color: Colors.green
                              .withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.copy,
                            size: 11,
                            color: Colors.green),
                        const SizedBox(width: 5),
                        Text(
                          tunnelAddress,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.green,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              Text(
                '${_activeServer?.version ?? '?'} · ${formatRam(_ramMb)} allocated',
                style: const TextStyle(
                    fontSize: 11, color: Colors.grey),
              ),
            ],
          ),

          SizedBox(height: isPhone ? 8 : 12),

          // Stats grid
          GridView.count(
            crossAxisCount: crossAxisCount,
            shrinkWrap: true,
            physics:
                const NeverScrollableScrollPhysics(),
            crossAxisSpacing: isPhone ? 6 : 10,
            mainAxisSpacing: isPhone ? 6 : 10,
            childAspectRatio: cardAspect,
            children: [
              _statCard(
                label: 'TPS',
                value: isOnline
                    ? s.tps.toStringAsFixed(1)
                    : '--',
                sublabel: 'ticks/sec',
                color: isOnline
                    ? tpsColor()
                    : Colors.grey,
                icon: Icons.speed,
                isPhone: isPhone,
              ),
              _statCard(
                label: 'Players',
                value: isOnline
                    ? '${s.playersOnline}/${s.maxPlayers}'
                    : '--',
                sublabel: 'online',
                color: isOnline
                    ? (s.playersOnline > 0
                        ? Colors.green
                        : Colors.grey)
                    : Colors.grey,
                icon: Icons.people,
                isPhone: isPhone,
              ),
              _statCard(
                label: 'RAM',
                value: isOnline
                    ? formatRam(s.ramUsedMb)
                    : '--',
                sublabel: isOnline
                    ? 'of ${formatRam(s.ramTotalMb)}'
                    : 'usage',
                color: isOnline
                    ? Colors.blue
                    : Colors.grey,
                icon: Icons.memory,
                isPhone: isPhone,
              ),
              _statCard(
                label: 'CPU',
                value: isOnline
                    ? '${s.cpuPercent.toStringAsFixed(1)}%'
                    : '--',
                sublabel: 'usage',
                color: isOnline
                    ? (s.cpuPercent < 70
                        ? Colors.green
                        : Colors.orange)
                    : Colors.grey,
                icon: Icons.developer_board,
                isPhone: isPhone,
              ),
              _statCard(
                label: 'Uptime',
                value: isOnline
                    ? _formatUptime(_uptime)
                    : '--:--:--',
                sublabel: 'hh:mm:ss',
                color: isOnline
                    ? Colors.purple
                    : Colors.grey,
                icon: Icons.timer,
                isPhone: isPhone,
              ),
              _statCard(
                label: 'Packet loss',
                value: isOnline
                    ? '${s.packetLoss.toStringAsFixed(0)}%'
                    : '--',
                sublabel: 'to host',
                color: isOnline
                    ? packetColor()
                    : Colors.grey,
                icon: Icons.network_check,
                isPhone: isPhone,
              ),
              _statCard(
                label: 'World',
                value: isOnline
                    ? formatSize(s.worldSizeMb)
                    : '--',
                sublabel: 'on disk',
                color: isOnline
                    ? Colors.teal
                    : Colors.grey,
                icon: Icons.storage,
                isPhone: isPhone,
              ),
              _statCard(
                label: 'Allocated',
                value: formatRam(_ramMb),
                sublabel: 'max heap',
                color: Colors.grey,
                icon: Icons.bar_chart,
                isPhone: isPhone,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statCard({
    required String label,
    required String value,
    required String sublabel,
    required Color color,
    required IconData icon,
    bool isPhone = false,
  }) {
    return Container(
      padding: EdgeInsets.all(isPhone ? 6 : 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(10),
        border:
            Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment:
            MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(icon,
                  size: isPhone ? 11 : 13,
                  color: color.withValues(alpha: 0.7)),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: isPhone ? 10 : 11,
                    height: 1.0,
                    color: color.withValues(alpha: 0.7),
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: isPhone ? 14 : 17,
              height: 1.0,
              fontWeight: FontWeight.w500,
              color: color,
              fontFamily: 'monospace',
            ),
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            sublabel,
            style: TextStyle(
              fontSize: isPhone ? 9 : 10,
              height: 1.0,
              color: Colors.grey,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
class SliverContainer extends StatelessWidget {
  final Widget sliver;
  final Color color;

  const SliverContainer({super.key, required this.sliver, required this.color});

  @override
  Widget build(BuildContext context) {
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(child: Container(color: color, height: 0)), // Dummy for color
        sliver,
      ],
    );
  }
}