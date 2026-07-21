import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;
import 'package:archive/archive_io.dart';
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
  frp,
  portForward,
  // Adding another provider later (ngrok, cloudflared, etc.) means:
  // write a class implementing TunnelProvider below, add a case for it
  // in TunnelService._createProvider, and add it to this enum. Nothing
  // in the UI layer needs to know how a given provider works internally
  // — it only ever talks to TunnelService.
}

extension TunnelProviderTypeInfo on TunnelProviderType {
  String get displayName {
    switch (this) {
      case TunnelProviderType.playit:
        return 'Playit.gg';
      case TunnelProviderType.frp:
        return 'Your own VPS (frp)';
      case TunnelProviderType.portForward:
        return 'Port Forwarding';
    }
  }

  String get shortDescription {
    switch (this) {
      case TunnelProviderType.playit:
        return 'Free, one-click, zero setup. Windows/Linux only.';
      case TunnelProviderType.frp:
        return 'No caps, full control. Needs your own always-on server.';
      case TunnelProviderType.portForward:
        return 'Best option if it works — direct, free, no relay. Needs a real public IP (not CGNAT).';
    }
  }

  /// Whether this provider can realistically work on the current device
  /// at all. Playit's official binaries are Rust/glibc and don't run on
  /// Android's Bionic libc; the other two work anywhere.
  bool get availableOnThisPlatform {
    if (this == TunnelProviderType.playit) {
      return Platform.isWindows || Platform.isLinux;
    }
    return true;
  }
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

/// frp (fast reverse proxy) — a self-hosted alternative to playit. Unlike
/// playit, there's no free relay: you (or whoever) must already be
/// running an `frps` server somewhere with a real public IP (a free-tier
/// cloud VM is the usual way people do this). In exchange, there's no
/// bandwidth cap and no account requirement, and — importantly — frpc is
/// a statically-linked Go binary, so unlike playit (Rust, dynamically
/// linked against glibc) it actually runs on Android: Go binaries don't
/// need glibc, so the plain Linux arm64 release genuinely executes under
/// this app's Termux-style environment instead of crashing on a missing
/// library the way playit's binary does.
///
/// Must be configured via [configure] before [start] is called — there's
/// no auto-discovery step here, you already know your own server's
/// address.
class FrpTunnelProvider implements TunnelProvider {
  Process? _process;
  final _outputController = StreamController<String>.broadcast();
  final _statusController = StreamController<TunnelStatus>.broadcast();
  bool _isRunning = false;
  String? _tunnelAddress;

  String? _serverAddr;
  int _serverPort = 7000;
  String? _authToken;
  int _remotePort = 25565;

  @override
  Stream<String> get output => _outputController.stream;
  @override
  Stream<TunnelStatus> get status => _statusController.stream;
  @override
  bool get isRunning => _isRunning;
  @override
  String? get tunnelAddress => _tunnelAddress;
  @override
  String? get claimUrl => null; // frp has no claim flow — nothing to do

  /// Must be called at least once before [start]. [serverAddr] should be
  /// an IP address rather than a hostname where possible — the plain
  /// Linux frpc build has a known DNS-resolution quirk on some Android
  /// setups, and a raw IP sidesteps it entirely.
  void configure({
    required String serverAddr,
    int serverPort = 7000,
    required String authToken,
    int remotePort = 25565,
  }) {
    _serverAddr = serverAddr;
    _serverPort = serverPort;
    _authToken = authToken;
    _remotePort = remotePort;
  }

  bool get isConfigured => _serverAddr != null && _authToken != null;

  /// frp's official releases don't include a dedicated Android/Bionic
  /// build — this uses the plain linux_arm64 build on Android, which
  /// (unlike playit) actually runs there because Go binaries are
  /// statically linked. Covers the overwhelming majority of modern
  /// Android devices (arm64); very old 32-bit devices aren't handled.
  String? _assetSuffixForPlatform() {
    if (Platform.isWindows) return 'windows_amd64.zip';
    if (Platform.isAndroid) return 'linux_arm64.tar.gz';
    if (Platform.isLinux) return 'linux_amd64.tar.gz';
    return null;
  }

  Future<String?> _ensureBinary(void Function(String) onStatus) async {
    final suffix = _assetSuffixForPlatform();
    if (suffix == null) {
      onStatus('[Tunnel] frp doesn\'t have a build for this platform.');
      return null;
    }

    final binName = Platform.isWindows ? 'frpc.exe' : 'frpc';
    final toolsPath = await PlatformService.getToolsPath();
    final dir = Directory(p.join(toolsPath, 'tunnels', 'frp'));
    final exePath = p.join(dir.path, binName);
    final exeFile = File(exePath);

    if (await exeFile.exists()) {
      return exePath;
    }

    onStatus('[Tunnel] Setting up frp (one-time download)...');
    await dir.create(recursive: true);

    String? downloadUrl;
    try {
      final resp = await http.get(Uri.parse(
          'https://api.github.com/repos/fatedier/frp/releases/latest'));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final assets = (data['assets'] as List?) ?? [];
        for (final a in assets) {
          final name = a['name'] as String? ?? '';
          if (name.endsWith(suffix)) {
            downloadUrl = a['browser_download_url'] as String?;
            break;
          }
        }
      } else {
        onStatus(
            '[Tunnel] Could not reach GitHub to fetch frp (HTTP ${resp.statusCode}).');
      }
    } catch (e) {
      onStatus('[Tunnel] Failed to check for frp release: $e');
    }

    if (downloadUrl == null) {
      onStatus('[Tunnel] Could not find an frp download for this platform.');
      return null;
    }

    final archivePath = p.join(
        dir.path, suffix.endsWith('.zip') ? 'frp.zip' : 'frp.tar.gz');
    final ok = await PlatformService.downloadFile(
      url: downloadUrl,
      destPath: archivePath,
      onStatus: onStatus,
    );
    if (!ok) return null;

    onStatus('[Tunnel] Extracting frp...');
    try {
      // Only pull the frpc binary itself out of the archive — the
      // release also bundles frps, example configs, and a license we
      // don't need.
      final List<int> Function(ArchiveFile) contentOf =
          (f) => f.content as List<int>;

      if (suffix.endsWith('.zip')) {
        final bytes = await File(archivePath).readAsBytes();
        final archive = ZipDecoder().decodeBytes(bytes);
        for (final file in archive) {
          if (p.basename(file.name) == binName) {
            await exeFile.create(recursive: true);
            await exeFile.writeAsBytes(contentOf(file));
            break;
          }
        }
      } else {
        final inputStream = InputFileStream(archivePath);
        final archive =
            TarDecoder().decodeBytes(GZipDecoder().decodeBuffer(inputStream));
        for (final file in archive) {
          if (p.basename(file.name) == binName) {
            await exeFile.create(recursive: true);
            await exeFile.writeAsBytes(contentOf(file));
            break;
          }
        }
      }

      await File(archivePath).delete();

      if (!await exeFile.exists()) {
        onStatus('[Tunnel] Couldn\'t find frpc inside the downloaded archive.');
        return null;
      }

      if (!Platform.isWindows) {
        // Includes Android — chmod is a basic toolbox command that's
        // present on stock /system/bin. If this doesn't actually take
        // effect on a given device, that's the one thing about this
        // provider that would need moving into native (Kotlin) code
        // instead, the same way Java installation already is on Android.
        await Process.run('chmod', ['+x', exePath]);
      }

      onStatus('[Tunnel] frp ready.');
      return exePath;
    } catch (e) {
      onStatus('[Tunnel] Extraction failed: $e');
      return null;
    }
  }

  Future<String> _writeConfig(String dir) async {
    final configPath = p.join(dir, 'frpc.toml');
    final toml = '''
serverAddr = "$_serverAddr"
serverPort = $_serverPort
auth.token = "$_authToken"
loginFailExit = false

[[proxies]]
name = "minecraft"
type = "tcp"
localIP = "127.0.0.1"
localPort = 25565
remotePort = $_remotePort
''';
    await File(configPath).writeAsString(toml);
    return configPath;
  }

  @override
  Future<bool> start({required int localPort}) async {
    if (_isRunning) return false;
    if (!isConfigured) {
      _outputController.add(
          '[Tunnel] frp needs a server address and token configured first.');
      _statusController.add(TunnelStatus.error);
      return false;
    }

    final exePath = await _ensureBinary((s) => _outputController.add(s));
    if (exePath == null) {
      _statusController.add(TunnelStatus.error);
      return false;
    }

    try {
      final configPath = await _writeConfig(p.dirname(exePath));
      _outputController.add('[Tunnel] Starting frpc...');

      _process = await Process.start(
        exePath,
        ['-c', configPath],
        workingDirectory: p.dirname(exePath),
      );

      _isRunning = true;
      _statusController.add(TunnelStatus.connecting);
      _outputController.add('[Tunnel] Process started, PID: ${_process!.pid}');

      _process!.stdout
          .transform(SystemEncoding().decoder)
          .listen(_handleOutput);
      _process!.stderr
          .transform(SystemEncoding().decoder)
          .listen(_handleOutput);

      _process!.exitCode.then((code) {
        _isRunning = false;
        _statusController.add(TunnelStatus.stopped);
        _outputController.add('[Tunnel stopped with exit code $code]');
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
    // frpc's exact log wording varies a bit by version — this matches
    // on the keywords that have stayed consistent, rather than one
    // exact phrase. If it connects but status never flips to
    // "connected" here, paste the raw output (Copy all, in the console
    // header) and this can be tightened.
    final lower = line.toLowerCase();

    if (lower.contains('login to server failed') ||
        lower.contains('authentication failed')) {
      _statusController.add(TunnelStatus.error);
      return;
    }

    if (lower.contains('login to server success')) {
      _statusController.add(TunnelStatus.connecting);
      return;
    }

    if ((lower.contains('start proxy success') ||
            lower.contains('proxy added')) &&
        lower.contains('minecraft')) {
      _tunnelAddress = '$_serverAddr:$_remotePort';
      _statusController.add(TunnelStatus.connected);
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
  Future<String> resetAgent() async {
    return 'frp has no agent to reset — just update the server details.';
  }

  @override
  void dispose() {
    _outputController.close();
    _statusController.close();
  }
}

/// Port forwarding — not really a "provider" in the sense of running
/// software at all. If your router has a real public IP (i.e. you're
/// not behind CGNAT) and you've forwarded the Minecraft port to this
/// device, this is the best option that exists: no relay, no bandwidth
/// cap, no third party, lowest possible latency. This class doesn't and
/// can't configure your router — routers don't expose a universal API
/// for that — it only detects what address to tell players, and gives
/// an honest best-effort read on whether it looks reachable.
class PortForwardProvider implements TunnelProvider {
  final _outputController = StreamController<String>.broadcast();
  final _statusController = StreamController<TunnelStatus>.broadcast();
  bool _isRunning = false;
  String? _tunnelAddress;
  int _port = 25565;

  @override
  Stream<String> get output => _outputController.stream;
  @override
  Stream<TunnelStatus> get status => _statusController.stream;
  @override
  bool get isRunning => _isRunning;
  @override
  String? get tunnelAddress => _tunnelAddress;
  @override
  String? get claimUrl => null;

  /// Local LAN IP of this device — this is what you forward the port
  /// *to* in your router's settings.
  Future<String?> getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<bool> start({required int localPort}) async {
    if (_isRunning) return false;
    _port = localPort;

    _outputController.add('[Tunnel] Checking your network...');
    _statusController.add(TunnelStatus.connecting);

    final localIp = await getLocalIp();
    if (localIp != null) {
      _outputController.add('[Tunnel] Local IP: $localIp (forward port $_port to this in your router)');
    } else {
      _outputController.add('[Tunnel] Could not detect a local IP.');
    }

    String? publicIp;
    try {
      final resp = await http
          .get(Uri.parse('https://api.ipify.org'))
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode == 200) publicIp = resp.body.trim();
    } catch (e) {
      _outputController.add('[Tunnel] Could not detect your public IP: $e');
    }

    if (publicIp == null) {
      _isRunning = false;
      _statusController.add(TunnelStatus.error);
      return false;
    }

    // A CGNAT-assigned address always falls in 100.64.0.0/10. If your
    // *local* IP is in this range, that's your router's WAN address
    // handed to it by the ISP — a strong sign port forwarding can't
    // work here no matter how it's configured, since your router was
    // never given a real public address to forward from.
    final looksLikeCgnat =
        RegExp(r'^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.').hasMatch(publicIp);
    if (looksLikeCgnat) {
      _outputController.add(
          '[Tunnel] Warning: $publicIp looks like a CGNAT address, not a real public IP. Port forwarding likely won\'t work on this network.');
    }

    _tunnelAddress = '$publicIp:$_port';
    _isRunning = true;
    _outputController.add(
        '[Tunnel] Detected address: $_tunnelAddress — this only works once the port is actually forwarded in your router, which this app can\'t verify or configure for you.');
    _statusController.add(TunnelStatus.connected);
    return true;
  }

  @override
  Future<void> stop() async {
    _isRunning = false;
    _tunnelAddress = null;
    _statusController.add(TunnelStatus.stopped);
  }

  @override
  Future<String> resetAgent() async {
    return 'Nothing to reset — port forwarding is just detection, not a running service.';
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
      case TunnelProviderType.frp:
        return FrpTunnelProvider();
      case TunnelProviderType.portForward:
        return PortForwardProvider();
    }
  }

  Stream<String> get output => _outputController.stream;
  Stream<TunnelStatus> get status => _statusController.stream;
  bool get isRunning => _provider?.isRunning ?? false;
  String? get tunnelAddress => _provider?.tunnelAddress;
  String? get claimUrl => _provider?.claimUrl;

  /// Only meaningful once the frp provider is selected via setProvider —
  /// no-op otherwise. frp needs your own server's details since there's
  /// no free relay behind it the way playit has.
  void configureFrp({
    required String serverAddr,
    int serverPort = 7000,
    required String authToken,
    int remotePort = 25565,
  }) {
    final provider = _provider;
    if (provider is FrpTunnelProvider) {
      provider.configure(
        serverAddr: serverAddr,
        serverPort: serverPort,
        authToken: authToken,
        remotePort: remotePort,
      );
    }
  }

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