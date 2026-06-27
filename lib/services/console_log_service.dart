import 'dart:io';
import 'package:path/path.dart' as p;
import 'platform_service.dart';

class ConsoleLogService {
  static const int _maxBytes = 2 * 1024 * 1024;
  static const int _trimBytes = 1 * 1024 * 1024;

  IOSink? _sink;
  File? _logFile;

  Future<void> init(String serverPath) async {
    await close();
    try {
      final native =
          await PlatformService.toNativePath(
              serverPath);
      final logsDir = Directory(
          Platform.isWindows
              ? '$native\\logs'
              : '$native/logs');
      await logsDir.create(recursive: true);

      _logFile = File(Platform.isWindows
          ? '${logsDir.path}\\console.log'
          : '${logsDir.path}/console.log');

      // Always start fresh — overwrite not append
      _sink = _logFile!.openWrite(
          mode: FileMode.writeOnly);

      // Write session header with timestamp
      final now = DateTime.now();
      final ts = _formatTimestamp(now);
      _sink!.writeln(
          '[$ts] === New session started ===');
    } catch (e) {
      print('ConsoleLogService init error: $e');
    }
  }

  String _formatTimestamp(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  void write(String line) {
    try {
      if (_sink == null) return;
      final ts =
          _formatTimestamp(DateTime.now());
      // Don't double-timestamp lines that
      // already have MC timestamps like [17:39:37]
      final hasTimestamp =
          RegExp(r'^\[\d{2}:\d{2}:\d{2}\]')
              .hasMatch(line.trim());
      if (hasTimestamp || line.startsWith('[')) {
        _sink!.writeln(line);
      } else {
        _sink!.writeln('[$ts] $line');
      }
    } catch (_) {}
  }

  Future<void> close() async {
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {}
    _sink = null;
    _logFile = null;
  }
}