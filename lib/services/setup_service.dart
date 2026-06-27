import 'dart:io';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'platform_service.dart';

class SetupStatus {
  final String message;
  final double progress;
  final bool done;
  final bool success;
  final bool isError;

  const SetupStatus({
    required this.message,
    required this.progress,
    this.done = false,
    this.success = false,
    this.isError = false,
  });
}

class SetupService {
  static const _setupCompleteKey = 'setup_complete_v2';
  final _statusController =
      StreamController<SetupStatus>.broadcast();
  Stream<SetupStatus> get status => _statusController.stream;

  void _emit(String message, double progress,
      {bool done = false,
      bool success = false,
      bool isError = false}) {
    _statusController.add(SetupStatus(
      message: message,
      progress: progress,
      done: done,
      success: success,
      isError: isError,
    ));
  }

  static Future<bool> isSetupComplete() async {
    final base = await PlatformService.getAppFilesPath();
    final marker = File(p.join(base, '.setup_complete'));
    return marker.existsSync();
  }

  static Future<void> markSetupComplete() async {
    final base = await PlatformService.getAppFilesPath();
    await Directory(base).create(recursive: true);
    await File(p.join(base, '.setup_complete'))
        .writeAsString('ok');
  }

  Future<bool> runSetup() async {
    try {
      if (Platform.isWindows) {
        return await _setupWindows();
      } else if (Platform.isAndroid) {
        return await _setupAndroid();
      }
      return true;
    } catch (e) {
      _emit('Setup failed: $e', 0,
          done: true, success: false, isError: true);
      return false;
    }
  }

  // ─── Windows setup ─────────────────────────────────
  Future<bool> _setupWindows() async {
    _emit('Setting up PocketServer...', 0.05);

    final base = await PlatformService.getAppFilesPath();
    final toolsPath = p.join(base, 'tools');
    final binPath = p.join(toolsPath, 'bin');

    await Directory(binPath).create(recursive: true);
    await Directory(p.join(base, 'servers'))
        .create(recursive: true);

    _emit('Extracting portable shell...', 0.1);
    await _extractWindowsAsset(
        'assets/tools/windows/busybox.exe',
        p.join(binPath, 'busybox.exe'));

    // Verify busybox works
    _emit('Verifying shell...', 0.7);
    final test = await Process.run(
        p.join(binPath, 'busybox.exe'),
        ['sh', '-c', 'echo ok'],
        runInShell: false);
    _emit('Shell test: ${test.stdout.toString().trim()}', 0.8);

    _emit('Extracting download tools...', 0.2);
    await _extractWindowsAsset(
        'assets/tools/windows/wget.exe',
        p.join(binPath, 'wget.exe'));

    _emit('Configuring shell...', 0.3);
    final busyboxPath = p.join(binPath, 'busybox.exe');
    final bashPath = p.join(binPath, 'bash.exe');
    final shPath = p.join(binPath, 'sh.exe');

    await File(busyboxPath)
        .copy(bashPath);
    await File(busyboxPath)
        .copy(shPath);

    PlatformService.setBashPath(busyboxPath);
    PlatformService.setWgetPath(
        p.join(binPath, 'wget.exe'));

    _emit('Setup complete!', 1.0,
        done: true, success: true);
    await markSetupComplete();
    return true;
  }

  Future<void> _extractWindowsAsset(
      String assetPath, String destPath) async {
    final data = await rootBundle.load(assetPath);
    final bytes = data.buffer.asUint8List();
    await File(destPath).writeAsBytes(bytes);
  }

  // ─── Android setup ─────────────────────────────────
  Future<bool> _setupAndroid() async {
    _emit('Setting up PocketServer...', 0.05);

    final base = await PlatformService.getAppFilesPath();
    await Directory(p.join(base, 'servers'))
        .create(recursive: true);
    await Directory(p.join(base, 'tools'))
        .create(recursive: true);

    _emit('Initialising environment...', 0.1);
    final scriptData = await rootBundle
        .loadString('assets/tools/android/setup.sh');
    final scriptPath = p.join(base, 'setup.sh');
    await File(scriptPath)
        .writeAsString(scriptData);
    await Process.run(
        '/system/bin/chmod', ['755', scriptPath]);
    await Process.run(
        '/system/bin/sh', [scriptPath]);

    _emit('Downloading Java 17 (~190MB)...', 0.15);

    final javaOk = await PlatformService.ensureJava(
      17,
      (msg) {
        // Parse progress from download messages
        double prog = 0.15;
        if (msg.contains('MB')) {
          final match =
              RegExp(r'([\d.]+)MB / ([\d.]+)MB')
                  .firstMatch(msg);
          if (match != null) {
            final received =
                double.tryParse(match.group(1)!) ??
                    0;
            final total =
                double.tryParse(match.group(2)!) ??
                    1;
            prog = 0.15 + (received / total) * 0.7;
          }
        } else if (msg.contains('Extracting')) {
          prog = 0.87;
        } else if (msg.contains('ready')) {
          prog = 0.95;
        }
        _emit(msg, prog);
      },
    );

    if (!javaOk) {
      _emit('Java download failed', 0,
          done: true, success: false, isError: true);
      return false;
    }

    _emit('Setup complete!', 1.0,
        done: true, success: true);
    await markSetupComplete();
    return true;
  }

  double _lastProgress = 0;

  void dispose() {
    _statusController.close();
  }
}