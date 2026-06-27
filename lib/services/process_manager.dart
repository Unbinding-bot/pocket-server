import 'dart:io';
import 'dart:async';
import '../models/server_properties.dart';
import 'java_downloader.dart';
import 'server_properties_service.dart';
import 'platform_service.dart';
import 'termux_env_service.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart';

class ServerProcess {
  Process? _process;
  final _outputController =
      StreamController<String>.broadcast();
  bool _isRunning = false;
  Timer? _logPoller;
 
  Stream<String> get output => _outputController.stream;
  bool get isRunning => _isRunning;

  Future<bool> ensureServerJar({
    required String serverPath,
    required String version,
    required Function(String) onStatus,
    ServerType type = ServerType.vanilla,
  }) async {
    // Use Dart file API directly — no shell needed
    if (type == ServerType.fabric) {
      final marker = File(
          Platform.isWindows
              ? '$serverPath\\.is_fabric'
              : '$serverPath/.is_fabric');
      if (marker.existsSync()) return true;
    } else {
      final jar = File(
          Platform.isWindows
              ? '$serverPath\\server.jar'
              : '$serverPath/server.jar');
      if (jar.existsSync()) return true;
    }

    onStatus(
        '[Server] Downloading $version '
        '(${type.displayName})...');
    final downloader = JavaDownloader();
    downloader.progress
        .listen((p) => onStatus('[Server] ${p.status}'));

    final ok = await downloader.downloadServerJar(
      version: version,
      serverPath: serverPath,
      type: type,
    );

    downloader.dispose();
    return ok;
  }

  Future<bool> startServer({
    required String serverPath,
    required String javaPath,
    required int ramMb,
    required String version,
    required Function(String) onStatus,
    ServerProperties? properties,
    String serverType = 'vanilla',
  }) async {
    if (_isRunning) return false;

    try {
      final type = ServerType.values.firstWhere(
        (e) => e.name == serverType,
        orElse: () => ServerType.vanilla,
      );

      final jarReady = await ensureServerJar(
        serverPath: serverPath,
        version: version,
        onStatus: onStatus,
        type: type,
      );

      if (!jarReady) {
        _outputController
            .add('[Server] Failed to get server jar');
        return false;
      }

      if (properties != null) {
        final propsService = ServerPropertiesService();
        await propsService.apply(
          serverPath: serverPath,
          properties: properties,
        );
      }

      onStatus('[Server] Starting...');

      final javaVer =
          PlatformService.javaVersionForMc(version);

      if (Platform.isAndroid) {
        return await _startAndroid(
          serverPath: serverPath,
          ramMb: ramMb,
          version: version,
          serverType: serverType,
          onStatus: onStatus,
        );
      } else {
        return await _startDesktop(
          serverPath: serverPath,
          ramMb: ramMb,
          version: version,
          javaVer: javaVer,
          serverType: serverType,
          onStatus: onStatus,
        );
      }
    } catch (e) {
      _outputController
          .add('[Failed to start server: $e]');
      return false;
    }
  }

  Future<bool> _startAndroid({
    required String serverPath,
    required int ramMb,
    required String version,
    required String serverType,
    required Function(String) onStatus,
  }) async {
    final isFabric =
        File('$serverPath/.is_fabric').existsSync();
    final serverJar = isFabric
        ? 'fabric-server-launch.jar'
        : 'server.jar';

    final javaVer =
        PlatformService.javaVersionForMc(version);

    onStatus('[Server] Starting via Termux env...');

    // Ensure correct Java version is installed
    if (javaVer >= 21) {
      await TermuxEnvService.ensureJava21(onStatus);
    } else if (javaVer <= 8) {
      await TermuxEnvService.ensureJava8(onStatus);
    }

    try {
      _process = await TermuxEnvService.startServer(
        serverPath: serverPath,
        ramMb: ramMb,
        serverJar: serverJar,
        javaVersion: javaVer,
      );

      _isRunning = true;

      _process!.stdout
          .transform(SystemEncoding().decoder)
          .listen((line) {
        _outputController.add(line);
      });

      _process!.stderr
          .transform(SystemEncoding().decoder)
          .listen((line) {
        _outputController.add(line);
      });

      _process!.exitCode.then((code) {
        _isRunning = false;
        _logPoller?.cancel();
        _outputController.add(
            '[Server stopped with exit code $code]');
      });

      return true;
    } catch (e) {
      _outputController
          .add('[Failed to start: $e]');
      return false;
    }
  }

  String _toMsysPath(String windowsPath) {
    // Convert C:\foo\bar to /c/foo/bar for busybox
    if (windowsPath.length >= 2 &&
        windowsPath[1] == ':') {
      final drive =
          windowsPath[0].toLowerCase();
      final rest = windowsPath
          .substring(2)
          .replaceAll('\\', '/');
      return '/$drive$rest';
    }
    return windowsPath.replaceAll('\\', '/');
  }

  Future<bool> _startDesktop({
    required String serverPath,
    required int ramMb,
    required String version,
    required int javaVer,
    required String serverType,
    required Function(String) onStatus,
  }) async {
    final javaOk = await PlatformService.ensureJava(
        javaVer, onStatus);
    if (!javaOk) {
      _outputController
          .add('[Server] Java not available');
      return false;
    }

    final javaHome =
        await PlatformService.getJavaHome(javaVer);

    // Use forward slashes for java path only
    final javaExec = Platform.isWindows
        ? '$javaHome\\bin\\java.exe'
        : '$javaHome/bin/java';

    final isFabric =
        File(p.join(serverPath, '.is_fabric'))
            .existsSync();

    String startCmd;
    if (Platform.isWindows) {
      // On Windows use cmd.exe directly, not busybox
      // This avoids all path conversion issues
      final jar = isFabric
          ? 'fabric-server-launch.jar'
          : 'server.jar';
      startCmd = serverType == 'forge'
          ? 'if exist "$serverPath\\run.bat" '
              '(cd /d "$serverPath" && run.bat) '
              'else (cd /d "$serverPath" && '
              '"$javaExec" -Xmx${ramMb}M '
              '-Xms${ramMb ~/ 2}M '
              '-jar server.jar nogui)'
          : 'cd /d "$serverPath" && '
              '"$javaExec" -Xmx${ramMb}M '
              '-Xms${ramMb ~/ 2}M '
              '-jar "$jar" nogui';
    } else {
      startCmd = isFabric
          ? 'cd "$serverPath" && '
              '"$javaExec" '
              '-Xmx${ramMb}M -Xms${ramMb ~/ 2}M '
              '-jar fabric-server-launch.jar nogui'
          : serverType == 'forge'
              ? 'cd "$serverPath" && '
                  'if [ -f run.sh ]; then '
                  'bash run.sh nogui; '
                  'else "$javaExec" '
                  '-Xmx${ramMb}M -Xms${ramMb ~/ 2}M '
                  '-jar server.jar nogui; fi'
              : 'cd "$serverPath" && '
                  '"$javaExec" '
                  '-Xmx${ramMb}M -Xms${ramMb ~/ 2}M '
                  '-jar server.jar nogui';
    }

    print('[process_manager] startCmd: $startCmd');

    // On Windows use cmd.exe directly
    if (Platform.isWindows) {
      _process = await Process.start(
          'cmd.exe', ['/c', startCmd],
          runInShell: false,
          workingDirectory: serverPath);
    } else {
      _process =
          await PlatformService.startProcess(startCmd);
    }

    _isRunning = true;

    _process!.stdout
        .transform(SystemEncoding().decoder)
        .listen((line) {
      _outputController.add(line);
    });

    _process!.stderr
        .transform(SystemEncoding().decoder)
        .listen((line) {
      _outputController.add(line);
    });

    _process!.exitCode.then((code) {
      _isRunning = false;
      _outputController.add(
          '[Server stopped with exit code $code]');
    });

    return true;
  }

  Future<void> sendCommand(String command) async {
    if (!_isRunning || _process == null) return;
    _process!.stdin.writeln(command);
  }

  Future<void> stopServer() async {
    if (!_isRunning) return;
    await sendCommand('stop');
    await Future.delayed(
        const Duration(seconds: 10));
    if (_isRunning) _process?.kill();
    _logPoller?.cancel();
  }

  void dispose() {
    _logPoller?.cancel();
    _outputController.close();
  }
}