import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

class PlatformService {
  static String? _bashPath;
  static String? _wgetPath;

  static void setBashPath(String path) =>
      _bashPath = path;
  static void setWgetPath(String path) =>
      _wgetPath = path;

  // ─── App file paths ───────────────────────────────
  static Future<String> getAppFilesPath() async {
    if (Platform.isAndroid) {
      return '/data/data/com.example.pocket_server/files';
    } else if (Platform.isWindows) {
      final dir =
          await getApplicationDocumentsDirectory();
      return p.join(dir.path, 'PocketServer');
    }
    final dir =
        await getApplicationDocumentsDirectory();
    return dir.path;
  }

  static Future<String> getToolsPath() async {
    final base = await getAppFilesPath();
    return p.join(base, 'tools');
  }

  static Future<String> getBinPath() async {
    final tools = await getToolsPath();
    return p.join(tools, 'bin');
  }

  static Future<String> getJavaHome(
      int javaVersion) async {
    if (Platform.isAndroid) {
      return '/data/data/com.example.pocket_server'
          '/files/tools/java$javaVersion';
    }
    final tools = await getToolsPath();
    return p.join(tools, 'java$javaVersion');
  }

  static Future<String> getServersPath() async {
    final base = await getAppFilesPath();
    return p.join(base, 'servers');
  }

  // ─── Java version for MC version ──────────────────
  static int javaVersionForMc(String mcVersion) {
    final parts = mcVersion.split('.');
    if (parts.length < 2) return 17;
    final minor = int.tryParse(parts[1]) ?? 0;
    if (minor >= 21) return 21;
    if (minor >= 17) return 17;
    return 8;
  }

  // ─── Bash path ────────────────────────────────────
  static Future<String> getBashPath() async {
    if (Platform.isAndroid) return '/system/bin/sh';

    if (Platform.isWindows) {
      if (_bashPath != null &&
          _bashPath != 'wsl.exe' &&
          File(_bashPath!).existsSync()) {
        debugPrint('[PlatformService] Using cached bash: $_bashPath');
        return _bashPath!;
      }

      
      
      final binPath = await getBinPath();
      for (final name in ['busybox64.exe', 'busybox.exe']) {
        final busybox = p.join(binPath, name);
        if (File(busybox).existsSync()) {
          _bashPath = busybox;
          debugPrint('[PlatformService] Using busybox: $_bashPath');
          return _bashPath!;
        }
        debugPrint('[PlatformService] Checking busybox at: $busybox');
        debugPrint('[PlatformService] Exists: ${File(busybox).existsSync()}');
      }
      
      const gitPaths = [
        r'C:\Program Files\Git\bin\bash.exe',
        r'C:\Program Files\Git\usr\bin\bash.exe',
      ];
      for (final path in gitPaths) {
        debugPrint('[PlatformService] Checking git bash at: $path');
        if (File(path).existsSync()) {
          _bashPath = path;
          debugPrint('[PlatformService] Using git bash: $_bashPath');
          return _bashPath!;
        }
      }

      _bashPath = 'wsl.exe';
      debugPrint('[PlatformService] Falling back to wsl.exe');
      return _bashPath!;
    }

    _bashPath = '/bin/bash';
    return _bashPath!;
  }

  static Future<String?> getWgetPath() async {
    if (_wgetPath != null) return _wgetPath;
    if (Platform.isWindows) {
      final binPath = await getBinPath();
      final wget = p.join(binPath, 'wget.exe');
      if (File(wget).existsSync()) return wget;
    }
    return null;
  }

  // ─── Run command ──────────────────────────────────
  static Future<ProcessResult> runCommand(
      String command) async {
    if (Platform.isAndroid) {
      return Process.run(
          '/system/bin/sh', ['-c', command]);
    } else if (Platform.isWindows) {
      final bash = await getBashPath();
      if (bash == 'wsl.exe') {
        return Process.run(
            'wsl.exe', ['-e', 'bash', '-c', command]);
      }
      // busybox on Windows
      return Process.run(
          bash, ['sh', '-c', command],
          runInShell: false);
    }
    return Process.run('/bin/bash', ['-c', command]);
  }

  static Future<Process> startProcess(
      String command) async {
    if (Platform.isAndroid) {
      return Process.start(
          '/system/bin/sh', ['-c', command]);
    } else if (Platform.isWindows) {
      final bash = await getBashPath();
      debugPrint('[PlatformService] startProcess bash=$bash');
      debugPrint('[PlatformService] command=$command');
      if (bash == 'wsl.exe') {
        return Process.start(
            'wsl.exe', ['-e', 'bash', '-c', command]);
      }
      return Process.start(
          bash, ['sh', '-c', command],
          runInShell: false);
    }
    return Process.start('/bin/bash', ['-c', command]);
  }

  // ─── Download with progress ───────────────────────
  static Future<bool> downloadFile({
    required String url,
    required String destPath,
    required Function(String) onStatus,
  }) async {
    try {
      await Directory(p.dirname(destPath))
          .create(recursive: true);

      final client = http.Client();
      final request =
          http.Request('GET', Uri.parse(url));
      final response = await client.send(request);

      if (response.statusCode != 200) {
        onStatus(
            'Download failed: HTTP ${response.statusCode}');
        client.close();
        return false;
      }

      final total = response.contentLength ?? 0;
      int received = 0;
      final sink = File(destPath).openWrite();

      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          onStatus(
              'Downloading... '
              '${(received / 1024 / 1024).toStringAsFixed(1)}MB'
              ' / ${(total / 1024 / 1024).toStringAsFixed(0)}MB');
        } else {
          onStatus(
              'Downloading... '
              '${(received / 1024 / 1024).toStringAsFixed(1)}MB');
        }
      }

      await sink.flush();
      await sink.close();
      client.close();
      return true;
    } catch (e) {
      onStatus('Download error: $e');
      return false;
    }
  }

  // ─── Ensure Java (Windows/Linux only) ─────────────
  static Future<bool> ensureJava(
    int javaVersion,
    Function(String) onStatus,
  ) async {
    // On Android Java is handled by TermuxEnvService
    if (Platform.isAndroid) return true;

    final javaHome = await getJavaHome(javaVersion);
    final javaExec = Platform.isWindows
        ? p.join(javaHome, 'bin', 'java.exe')
        : p.join(javaHome, 'bin', 'java');

    if (File(javaExec).existsSync()) {
      onStatus('Java $javaVersion already installed');
      return true;
    }

    onStatus(
        'Downloading Java $javaVersion (~200MB)...');
    await Directory(javaHome).create(recursive: true);

    final url = _javaUrl(javaVersion);
    final isZip = url.endsWith('.zip');
    final tempFile = p.join(
        javaHome, isZip ? 'java.zip' : 'java.tar.gz');

    final ok = await downloadFile(
      url: url,
      destPath: tempFile,
      onStatus: onStatus,
    );

    if (!ok) {
      onStatus('Download failed');
      return false;
    }

    onStatus('Extracting Java $javaVersion...');

    try {
      if (isZip) {
        final bytes =
            await File(tempFile).readAsBytes();
        final archive =
            ZipDecoder().decodeBytes(bytes);
        for (final file in archive) {
          if (file.name.endsWith('/') || file.name.isEmpty) {
            continue;
          }
          final filePath =
              p.join(javaHome, file.name);
          try {
            await File(filePath)
                .create(recursive: true);
            await File(filePath).writeAsBytes(
                file.content as List<int>);
          } catch (_) {}
        }
      } else {
        final inputStream =
            InputFileStream(tempFile);
        final archive = TarDecoder().decodeBytes(
            GZipDecoder().decodeBuffer(inputStream));
        for (final file in archive) {
          if (file.name.endsWith('/') || file.name.isEmpty) {
            continue;
          }
          final filePath =
              p.join(javaHome, file.name);
          try {
            await File(filePath)
                .create(recursive: true);
            await File(filePath).writeAsBytes(
                file.content as List<int>);
          } catch (_) {}
        }
      }

      // Move up from subdirectory if needed
      final entries = Directory(javaHome)
          .listSync()
          .whereType<Directory>()
          .where((d) =>
              !p.basename(d.path).endsWith('.zip') &&
              !p.basename(d.path)
                  .endsWith('.tar.gz') &&
              !p.basename(d.path).startsWith('java.'))
          .toList();

      if (entries.length == 1) {
        onStatus('Moving Java files...');
        await _moveDir(entries.first.path, javaHome);
      }

      if (!Platform.isWindows) {
        await Process.run(
            'chmod', ['-R', '+x',
            p.join(javaHome, 'bin')]);
      }

      try {
        await File(tempFile).delete();
      } catch (_) {}

      if (!File(javaExec).existsSync()) {
        onStatus(
            'Java $javaVersion verification failed');
        return false;
      }

      onStatus('Java $javaVersion ready!');
      return true;
    } catch (e) {
      onStatus('Extraction failed: $e');
      return false;
    }
  }

  static String _javaUrl(int javaVersion) {
    if (Platform.isWindows) {
      switch (javaVersion) {
        case 21:
          return 'https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.5%2B11/OpenJDK21U-jdk_x64_windows_hotspot_21.0.5_11.zip';
        case 8:
          return 'https://github.com/adoptium/temurin8-binaries/releases/download/jdk8u432-b06/OpenJDK8U-jdk_x64_windows_hotspot_8u432b06.zip';
        default:
          return 'https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.13%2B11/OpenJDK17U-jdk_x64_windows_hotspot_17.0.13_11.zip';
      }
    }
    // Linux
    switch (javaVersion) {
      case 21:
        return 'https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.5%2B11/OpenJDK21U-jdk_x64_linux_hotspot_21.0.5_11.tar.gz';
      case 8:
        return 'https://github.com/adoptium/temurin8-binaries/releases/download/jdk8u432-b06/OpenJDK8U-jdk_x64_linux_hotspot_8u432b06.tar.gz';
      default:
        return 'https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.13%2B11/OpenJDK17U-jdk_x64_linux_hotspot_17.0.13_11.tar.gz';
    }
  }

  static Future<void> _moveDir(
      String source, String dest) async {
    final sourceDir = Directory(source);
    await for (final entity
        in sourceDir.list(recursive: false)) {
      final name = p.basename(entity.path);
      final destPath = p.join(dest, name);
      if (entity is File) {
        await entity.copy(destPath);
      } else if (entity is Directory) {
        await Directory(destPath)
            .create(recursive: true);
        await _moveDir(entity.path, destPath);
      }
    }
    await sourceDir.delete(recursive: true);
  }

  static Future<String> toNativePath(
      String linuxPath) async {
    if (Platform.isWindows) {
      if (linuxPath.contains(':\\') ||
          linuxPath.startsWith('\\\\')) {
        return linuxPath;
      }
      return linuxPath.replaceAll('/', '\\');
    }
    return linuxPath;
  }
}