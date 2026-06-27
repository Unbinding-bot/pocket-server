import 'dart:io';
import 'dart:async';

class TunnelService {

  String? _claimUrl;
  String? get claimUrl => _claimUrl;

  
  Process? _process;
  final _outputController = StreamController<String>.broadcast();
  final _statusController = StreamController<TunnelStatus>.broadcast();
  bool _isRunning = false;
  String? _tunnelAddress;

  Stream<String> get output => _outputController.stream;
  Stream<TunnelStatus> get status => _statusController.stream;
  bool get isRunning => _isRunning;
  String? get tunnelAddress => _tunnelAddress;

  Future<bool> start({required String playitBinaryPath}) async {
    if (_isRunning) return false;

    try {
      _outputController.add('[Tunnel] Starting playit...');
      
      _process = await Process.start(
        'wsl.exe',
        ['-e', playitBinaryPath, '-s', 'start'],
        runInShell: false,
      );

      _isRunning = true;
      _statusController.add(TunnelStatus.connecting);
      _outputController.add('[Tunnel] Process started, PID: ${_process!.pid}');

      _process!.stdout
          .transform(SystemEncoding().decoder)
          .listen((line) {
        _outputController.add('[TUNNEL] $line');
        _parseLine(line);
      });

      _process!.stderr
          .transform(SystemEncoding().decoder)
          .listen((line) {
        _outputController.add('[TUNNEL ERR] $line');
        _parseLine(line);
      });

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

  void _parseLine(String line) {
    // Connected with tunnels
    if (line.contains('tunnel running') &&
        line.contains('1 tunnels registered')) {
      _tunnelAddress ??=
          'body-respond.gl.joinmc.link';
      _statusController.add(TunnelStatus.connected);
      return;
    }

    // Connecting
    if (line.contains('starting up tunnel') ||
        line.contains('tunnel running, 0 tunnels')) {
      _statusController
          .add(TunnelStatus.connecting);
      return;
    }

    // Claim URL — multiple formats
    if (line.contains('playit.gg/claim') ||
        line.contains('https://playit.gg') ||
        line.contains('claim your agent')) {
      final match = RegExp(
              r'https://[a-zA-Z0-9./?=_%-]+')
          .firstMatch(line);
      if (match != null) {
        final url = match.group(0)!;
        _statusController
            .add(TunnelStatus.needsClaim);
        _outputController
            .add('[CLAIM] Open this URL: $url');
        _claimUrl = url;
      }
    }
  }

  Future<void> stop() async {
    if (!_isRunning || _process == null) return;
    _process!.kill();
    _isRunning = false;
    _tunnelAddress = null;
    _statusController.add(TunnelStatus.stopped);
  }

  void dispose() {
    _outputController.close();
    _statusController.close();
  }
}

enum TunnelStatus {
  stopped,
  connecting,
  connected,
  needsClaim,
} 