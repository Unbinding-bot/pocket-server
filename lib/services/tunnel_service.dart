import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;
import 'platform_service.dart';

enum TunnelStatus {
  stopped,
  connecting,
  connected,
  needsClaim,
  error,
}

enum TunnelProviderType {
  playit,
  // Adding another provider later (ngrok, cloudflared, etc.) means:
  // write a class implementing TunnelProvider below, add a case for it
  // in TunnelService._createProvider, and add it to this enum. Nothing
  // in the UI layer needs to know how a given provider works internally
  // — it only ever talks to TunnelService.
}

/// Common interface every tunnel backend implements.
abstract class TunnelProvider {
  Stream<String> get output;
  Stream<TunnelStatus> get status;
  bool get isRunning;
  String? get tunnelAddress;
  String? get claimUrl;
  Future<bool> start({required int localPort});
  Future<void> stop();
  Future<String> resetAgent();
  void dispose();
}

/// Real, native playit.gg tunnel — no WSL involved. Downloads the
/// official playit binary for the current OS on first use (straight
/// from GitHub releases, resolved dynamically so it doesn't go stale),
/// then runs it directly.
class PlayitTunnelProvider implements TunnelProvider {
  Process? _process;
  final _outputController = StreamController<String>.broadcast();
  final _statusController = StreamController<TunnelStatus>.broadcast();
  bool _isRunning = false;
  String? _tunnelAddress;
  String? _claimUrl;

  @override
  Stream<String> get output => _outputController.stream;
  @override
  Stream<TunnelStatus> get status => _statusController.stream;
  @override
  bool get isRunning => _isRunning;
  @override
  String? get tunnelAddress => _tunnelAddress;
  @override
  String? get claimUrl => _claimUrl;

  /// GitHub release asset name for the current platform. playit only
  /// publishes raw Windows/Linux binaries at the moment — no macOS
  /// binary is currently in their releases, so macOS isn't supported by
  /// this provider yet.
  String? _assetNameForPlatform() {
    if (Platform.isWindows) return 'playit-windows-x86_64-signed.exe';
    if (Platform.isLinux) return 'playit-linux-amd64';
    return null;
  }

  Future<String?> _ensureBinary(void Function(String) onStatus) async {
    final assetName = _assetNameForPlatform();
    if (assetName == null) {
      onStatus(
          '[Tunnel] playit doesn\'t have a build for this platform yet.');
      return null;
    }

    final toolsPath = await PlatformService.getToolsPath();
    final dir = Directory(p.join(toolsPath, 'tunnels', 'playit'));
    final exePath = p.join(dir.path, assetName);
    final exeFile = File(exePath);

    if (await exeFile.exists()) {
      return exePath;
    }

    onStatus('[Tunnel] Setting up playit (one-time download)...');
    await dir.create(recursive: true);

    String? downloadUrl;
    try {
      // Resolve whatever the current release is rather than hardcoding
      // a version — same approach the app already uses for MC/Fabric/
      // Forge versions, so this doesn't go stale as playit ships updates.
      final resp = await http.get(Uri.parse(
          'https://api.github.com/repos/playit-cloud/playit-agent/releases/latest'));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final assets = (data['assets'] as List?) ?? [];
        for (final a in assets) {
          if (a['name'] == assetName) {
            downloadUrl = a['browser_download_url'] as String?;
            break;
          }
        }
      } else {
        onStatus(
            '[Tunnel] Could not reach GitHub to fetch playit (HTTP ${resp.statusCode}).');
      }
    } catch (e) {
      onStatus('[Tunnel] Failed to check for playit release: $e');
    }

    if (downloadUrl == null) {
      onStatus(
          '[Tunnel] Could not find a playit download for this platform.');
      return null;
    }

    final ok = await PlatformService.downloadFile(
      url: downloadUrl,
      destPath: exePath,
      onStatus: onStatus,
    );
    if (!ok) return null;

    if (!Platform.isWindows) {
      // Raw Linux binaries from GitHub releases aren't marked
      // executable after download.
      await Process.run('chmod', ['+x', exePath]);
    }

    onStatus('[Tunnel] playit downloaded.');
    return exePath;
  }

  @override
  Future<bool> start({required int localPort}) async {
    if (_isRunning) return false;

    final exePath =
        await _ensureBinary((s) => _outputController.add(s));
    if (exePath == null) {
      _statusController.add(TunnelStatus.error);
      return false;
    }

    try {
      _outputController.add('[Tunnel] Starting playit...');

      // Run the binary directly — no WSL, no shell string. playit
      // manages its own claimed secret/config on disk by default and
      // reuses it automatically between runs, so nothing beyond the
      // working directory needs to be passed here.
      _process = await Process.start(
        exePath,
        const [],
        workingDirectory: p.dirname(exePath),
      );

      _isRunning = true;
      _statusController.add(TunnelStatus.connecting);
      _outputController
          .add('[Tunnel] Process started, PID: ${_process!.pid}');

      _process!.stdout
          .transform(SystemEncoding().decoder)
          .listen(_handleOutput);
      _process!.stderr
          .transform(SystemEncoding().decoder)
          .listen(_handleOutput);

      _process!.exitCode.then((code) {
        _isRunning = false;
        _statusController.add(TunnelStatus.stopped);
        _outputController
            .add('[Tunnel stopped with exit code $code]');
      });

      return true;
    } catch (e) {
      _isRunning = false;
      _outputController.add('[Tunnel] EXCEPTION: $e');
      _statusController.add(TunnelStatus.stopped);
      return false;
    }
  }

  void _handleOutput(String chunk) {
    for (final line in chunk.split('\n')) {
      if (line.trim().isEmpty) continue;
      _outputController.add('[TUNNEL] $line');
      _parseLine(line);
    }
  }

  void _parseLine(String line) {
    // Claim URL — only appears on first-time setup, and playit keeps
    // re-printing it until the link is opened and approved in a browser.
    if (line.contains('playit.gg/claim')) {
      final match =
          RegExp(r'https://[a-zA-Z0-9./?=_%-]+').firstMatch(line);
      if (match != null) {
        _claimUrl = match.group(0);
        _statusController.add(TunnelStatus.needsClaim);
        _outputController.add(
            '[CLAIM] Open this URL to finish setup: $_claimUrl');
      }
      return;
    }

    // The actual public address. playit's exact wording for this can
    // vary between versions, so rather than depending on one exact
    // phrase, this matches any hostname under playit's known domain
    // suffixes anywhere in the output. If the tunnel connects but the
    // address never shows up here, copy the raw console output (there's
    // a "Copy all" button in the console header) so this pattern can be
    // tightened to match the exact line your version prints.
    final addressMatch = RegExp(
      r'\b(?:[a-zA-Z0-9-]+\.)+(?:joinmc\.link|ply\.gg|playit\.gg)(?::\d+)?\b',
    ).firstMatch(line);
    if (addressMatch != null) {
      _tunnelAddress = addressMatch.group(0);
      _statusController.add(TunnelStatus.connected);
      return;
    }

    final lower = line.toLowerCase();
    if (lower.contains('tunnel running') ||
        lower.contains('starting up tunnel')) {
      _statusController.add(TunnelStatus.connecting);
    }
  }

  @override
  Future<String> resetAgent() async {
    final assetName = _assetNameForPlatform();
    if (assetName == null) return 'playit isn\'t set up on this platform.';

    final toolsPath = await PlatformService.getToolsPath();
    final exePath =
        p.join(toolsPath, 'tunnels', 'playit', assetName);
    if (!await File(exePath).exists()) {
      return 'playit hasn\'t been downloaded yet — nothing to reset.';
    }

    if (isRunning) await stop();

    try {
      // playit's own CLI has a `reset` subcommand that clears its saved
      // secret so it can be re-claimed — no WSL involved, just running
      // the same binary TunnelService already manages.
      final result = await Process.run(exePath, ['reset']);
      if (result.exitCode == 0) {
        _tunnelAddress = null;
        _claimUrl = null;
        return 'Agent reset. Start the tunnel again to reclaim it.';
      }
      return 'Reset failed: ${result.stderr}';
    } catch (e) {
      return 'Reset failed: $e';
    }
  }

  @override
  Future<void> stop() async {
    if (!_isRunning || _process == null) return;
    _process!.kill();
    _isRunning = false;
    _tunnelAddress = null;
    _statusController.add(TunnelStatus.stopped);
  }

  @override
  void dispose() {
    _outputController.close();
    _statusController.close();
  }
}

/// Public-facing service the rest of the app talks to. Keeps the exact
/// same surface the dashboard already uses (status/output/isRunning/
/// tunnelAddress/claimUrl/start/stop/dispose) but delegates internally
/// to whichever TunnelProvider is currently selected — so adding more
/// tunnel options later is just a new TunnelProvider, not a UI rewrite.
///
/// output/status are TunnelService's own stable broadcast streams (not
/// pass-through getters) so that a listener attached once — as the
/// dashboard does in initState — keeps working even if the underlying
/// provider is swapped out later via setProvider().
class TunnelService {
  TunnelProvider? _provider;
  TunnelProviderType _type = TunnelProviderType.playit;
  StreamSubscription<String>? _outputSub;
  StreamSubscription<TunnelStatus>? _statusSub;

  final _outputController = StreamController<String>.broadcast();
  final _statusController = StreamController<TunnelStatus>.broadcast();

  TunnelService() {
    _attachProvider(_createProvider(_type));
  }

  void _attachProvider(TunnelProvider provider) {
    _provider = provider;
    _outputSub = provider.output.listen(_outputController.add);
    _statusSub = provider.status.listen(_statusController.add);
  }

  TunnelProviderType get providerType => _type;

  static const availableProviders = TunnelProviderType.values;

  Future<void> setProvider(TunnelProviderType type) async {
    if (type == _type && _provider != null) return;
    await stop();
    await _outputSub?.cancel();
    await _statusSub?.cancel();
    _provider?.dispose();
    _type = type;
    _attachProvider(_createProvider(type));
  }

  TunnelProvider _createProvider(TunnelProviderType type) {
    switch (type) {
      case TunnelProviderType.playit:
        return PlayitTunnelProvider();
    }
  }

  Stream<String> get output => _outputController.stream;
  Stream<TunnelStatus> get status => _statusController.stream;
  bool get isRunning => _provider?.isRunning ?? false;
  String? get tunnelAddress => _provider?.tunnelAddress;
  String? get claimUrl => _provider?.claimUrl;

  Future<bool> start({int localPort = 25565}) async {
    return await _provider?.start(localPort: localPort) ?? false;
  }

  Future<void> stop() async {
    await _provider?.stop();
  }

  Future<String> resetAgent() async {
    return await _provider?.resetAgent() ??
        'No tunnel provider active.';
  }

  void dispose() {
    _outputSub?.cancel();
    _statusSub?.cancel();
    _provider?.dispose();
    _outputController.close();
    _statusController.close();
  }
}