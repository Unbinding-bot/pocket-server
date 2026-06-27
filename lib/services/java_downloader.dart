import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'platform_service.dart';

enum ServerType { vanilla, paper, fabric, forge }

extension ServerTypeExtension on ServerType {
  String get displayName {
    switch (this) {
      case ServerType.vanilla: return 'Vanilla';
      case ServerType.paper: return 'Paper';
      case ServerType.fabric: return 'Fabric';
      case ServerType.forge: return 'Forge';
    }
  }

  String get description {
    switch (this) {
      case ServerType.vanilla:
        return 'Official Mojang server, no mods';
      case ServerType.paper:
        return 'Best for plugins, great performance';
      case ServerType.fabric:
        return 'Lightweight mod loader';
      case ServerType.forge:
        return 'Most mods available, heavier';
    }
  }

  IconData get icon {
    switch (this) {
      case ServerType.vanilla: return Icons.grass;
      case ServerType.paper: return Icons.article;
      case ServerType.fabric: return Icons.texture;
      case ServerType.forge: return Icons.build;
    }
  }
}

class JavaDownloader {
  static List<String>? _vanillaCache;
  static List<String>? _paperCache;
  static List<String>? _fabricCache;
  static List<String>? _forgeCache;

  final _progressController =
      StreamController<DownloadProgress>.broadcast();
  Stream<DownloadProgress> get progress =>
      _progressController.stream;

  void _emit(String status, double progress,
      {bool done = false, bool success = false}) {
    _progressController.add(DownloadProgress(
      status: status,
      progress: progress,
      done: done,
      success: success,
    ));
  }
  Future<bool> _downloadJar({
    required String url,
    required String destPath,
    required String label,
  }) async {
    if (Platform.isAndroid) {
      // Use Dart HTTP on Android — no wget available
      try {
        _emit('Downloading $label...', 0.55);
        final client = http.Client();
        final request =
            http.Request('GET', Uri.parse(url));
        final response = await client.send(request);

        if (response.statusCode != 200) {
          _emit('Download failed: HTTP ${response.statusCode}',
              0, done: true, success: false);
          client.close();
          return false;
        }

        final total = response.contentLength ?? 0;
        int received = 0;
        final file = File(destPath);
        await file.parent.create(recursive: true);
        final sink = file.openWrite();

        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) {
            _emit(
              'Downloading $label... '
              '${(received / 1024 / 1024).toStringAsFixed(1)}MB'
              ' / ${(total / 1024 / 1024).toStringAsFixed(0)}MB',
              0.55 + (received / total) * 0.3,
            );
          }
        }

        await sink.flush();
        await sink.close();
        client.close();
        return true;
      } catch (e) {
        _emit('Download error: $e', 0,
            done: true, success: false);
        return false;
      }
    } else {
      // Use wget on Windows/Linux
      final result = await PlatformService.runCommand(
          'wget -q -O "$destPath" "$url"');
      return result.exitCode == 0;
    }
  }
  // ─── Version fetching ──────────────────────────────
  static Future<List<String>> versionsForType(
      ServerType type) async {
    switch (type) {
      case ServerType.vanilla:
        return await _vanillaVersions();
      case ServerType.paper:
        return await _paperVersions();
      case ServerType.fabric:
        return await _fabricVersions();
      case ServerType.forge:
        return await _forgeVersions();
    }
  }

  static Future<List<String>> _vanillaVersions() async {
    if (_vanillaCache != null) return _vanillaCache!;
    try {
      final r = await http
          .get(Uri.parse(
              'https://launchermeta.mojang.com/mc/game/version_manifest.json'))
          .timeout(const Duration(seconds: 8));
      if (r.statusCode == 200) {
        final data = jsonDecode(r.body);
        _vanillaCache = (data['versions'] as List)
            .where((v) => v['type'] == 'release')
            .map((v) => v['id'] as String)
            .toList();
        return _vanillaCache!;
      }
    } catch (_) {}
    return _vanillaFallback;
  }

  static Future<List<String>> _paperVersions() async {
    if (_paperCache != null) return _paperCache!;
    try {
      final r = await http
          .get(Uri.parse(
              'https://api.papermc.io/v2/projects/paper'))
          .timeout(const Duration(seconds: 8));
      if (r.statusCode == 200) {
        final data = jsonDecode(r.body);
        _paperCache = (data['versions'] as List)
            .map((v) => v.toString())
            .toList()
            .reversed
            .toList();
        return _paperCache!;
      }
    } catch (_) {}
    return _paperFallback;
  }

  static Future<List<String>> _fabricVersions() async {
    if (_fabricCache != null) return _fabricCache!;
    try {
      final r = await http
          .get(Uri.parse(
              'https://meta.fabricmc.net/v2/versions/game'))
          .timeout(const Duration(seconds: 8));
      if (r.statusCode == 200) {
        final data = jsonDecode(r.body) as List;
        _fabricCache = data
            .where((v) => v['stable'] == true)
            .map((v) => v['version'] as String)
            .toList();
        return _fabricCache!;
      }
    } catch (_) {}
    return _fabricFallback;
  }

  static Future<List<String>> _forgeVersions() async {
    if (_forgeCache != null) return _forgeCache!;
    // Forge API is unreliable — use fallback directly
    // and try API in background
    _forgeCache = _forgeFallback;
    try {
      final r = await http
          .get(Uri.parse(
              'https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json'))
          .timeout(const Duration(seconds: 8));
      if (r.statusCode == 200) {
        final data = jsonDecode(r.body);
        final promos =
            data['promos'] as Map<String, dynamic>;
        final versions = promos.keys
            .where((k) => k.endsWith('-recommended'))
            .map((k) =>
                k.replaceAll('-recommended', ''))
            .toList()
          ..sort((a, b) => b.compareTo(a));
        if (versions.isNotEmpty) {
          _forgeCache = versions;
        }
      }
    } catch (_) {}
    return _forgeCache!;
  }

  // ─── Fallbacks ─────────────────────────────────────
  static final _vanillaFallback = [
    '1.21.4', '1.21.3', '1.21.1', '1.21',
    '1.20.6', '1.20.4', '1.20.2', '1.20.1',
    '1.19.4', '1.19.2', '1.18.2', '1.17.1',
    '1.16.5', '1.15.2', '1.14.4', '1.13.2',
    '1.12.2', '1.11.2', '1.10.2', '1.9.4',
    '1.8.9', '1.7.10',
  ];
  static final _paperFallback = [
    '1.21.4', '1.21.3', '1.21.1', '1.21',
    '1.20.6', '1.20.4', '1.20.2', '1.20.1',
    '1.19.4', '1.19.2', '1.18.2', '1.17.1',
    '1.16.5', '1.15.2', '1.14.4', '1.13.2', '1.12.2',
  ];
  static final _fabricFallback = [
    '1.21.4', '1.21.3', '1.21.1', '1.21',
    '1.20.6', '1.20.4', '1.20.2', '1.20.1',
    '1.19.4', '1.19.2', '1.18.2', '1.17.1', '1.16.5',
  ];
  static final _forgeFallback = [
    '1.21.1', '1.20.4', '1.20.1', '1.19.4',
    '1.19.2', '1.18.2', '1.17.1', '1.16.5',
    '1.15.2', '1.14.4', '1.12.2',
  ];

  // ─── Download server jar ───────────────────────────
  Future<bool> downloadServerJar({
    required String version,
    required String serverPath,
    ServerType type = ServerType.vanilla,
  }) async {
    try {
      _emit('Creating server folder...', 0.02);

      // Create folder using Dart directly
      await Directory(serverPath).create(recursive: true);

      // Ensure correct Java version
      final javaVer =
          PlatformService.javaVersionForMc(version);
      final javaOk = await PlatformService.ensureJava(
        javaVer,
        (s) {
          // Parse MB progress from download messages
          final match = RegExp(
                  r'([\d.]+)MB\s*/\s*([\d.]+)MB')
              .firstMatch(s);
          if (match != null) {
            final recv =
                double.tryParse(match.group(1)!) ?? 0;
            final tot =
                double.tryParse(match.group(2)!) ?? 1;
            _emit(s, 0.05 + (recv / tot) * 0.35);
          } else {
            _emit(s, 0.1);
          }
        },
      );

      if (!javaOk) {
        _emit('Java install failed', 0,
            done: true, success: false);
        return false;
      }

      switch (type) {
        case ServerType.vanilla:
          return await _downloadVanilla(
              version, serverPath);
        case ServerType.paper:
          return await _downloadPaper(version, serverPath);
        case ServerType.fabric:
          return await _downloadFabric(
              version, serverPath);
        case ServerType.forge:
          return await _downloadForge(version, serverPath);
      }
    } catch (e) {
      _emit('Error: $e', 0, done: true, success: false);
      return false;
    }
  }

  Future<bool> _downloadVanilla(
      String version, String serverPath) async {
    _emit('Fetching Vanilla $version info...', 0.5);
    try {
      final manifestR = await http
          .get(Uri.parse(
              'https://launchermeta.mojang.com/mc/game/version_manifest.json'))
          .timeout(const Duration(seconds: 10));

      if (manifestR.statusCode != 200) {
        _emit('Manifest fetch failed', 0,
            done: true, success: false);
        return false;
      }

      final manifest = jsonDecode(manifestR.body);
      final versionInfo =
          (manifest['versions'] as List).firstWhere(
        (v) => v['id'] == version,
        orElse: () => null,
      );

      if (versionInfo == null) {
        _emit('Version $version not found', 0,
            done: true, success: false);
        return false;
      }

      _emit('Fetching Vanilla $version info...', 0.55);
      final versionR = await http
          .get(Uri.parse(versionInfo['url']))
          .timeout(const Duration(seconds: 10));
      final versionData = jsonDecode(versionR.body);
      final serverUrl =
          versionData['downloads']?['server']?['url'];

      if (serverUrl == null) {
        _emit('No server jar for $version', 0,
            done: true, success: false);
        return false;
      }

      // Always use Dart HTTP — no wget dependency
      final jarPath = '$serverPath/server.jar';
      _emit('Downloading Vanilla $version...', 0.6);

      final ok = await PlatformService.downloadFile(
        url: serverUrl,
        destPath: jarPath,
        onStatus: (s) => _emit(s, 0.6),
      );

      if (!ok) {
        _emit('Download failed', 0,
            done: true, success: false);
        return false;
      }

      return await _finalise(serverPath, version);
    } catch (e) {
      _emit('Vanilla error: $e', 0,
          done: true, success: false);
      return false;
    }
  }

  Future<bool> _downloadPaper(
      String version, String serverPath) async {
    _emit('Fetching Paper $version build...', 0.5);
    try {
      final r = await http
          .get(Uri.parse(
              'https://api.papermc.io/v2/projects/paper/versions/$version/builds'))
          .timeout(const Duration(seconds: 10));

      if (r.statusCode != 200) {
        _emit('Paper API error: ${r.statusCode}', 0,
            done: true, success: false);
        return false;
      }

      final data = jsonDecode(r.body);
      final builds = data['builds'] as List;
      if (builds.isEmpty) {
        _emit('No Paper builds for $version', 0,
            done: true, success: false);
        return false;
      }

      final build = builds.lastWhere(
        (b) => b['channel'] == 'default',
        orElse: () => builds.last,
      );
      final buildNum = build['build'];
      final jarName =
          build['downloads']['application']['name'];
      final url =
          'https://api.papermc.io/v2/projects/paper'
          '/versions/$version/builds/$buildNum'
          '/downloads/$jarName';

      final jarPath = '$serverPath/server.jar';
      final ok = await PlatformService.downloadFile(
        url: url,
        destPath: jarPath,
        onStatus: (s) => _emit(s, 0.65),
      );

      if (!ok) {
        _emit('Paper download failed', 0,
            done: true, success: false);
        return false;
      }

      return await _finalise(serverPath, version,
          type: 'Paper');
    } catch (e) {
      _emit('Paper error: $e', 0,
          done: true, success: false);
      return false;
    }
  }

  Future<bool> _downloadFabric(
      String version, String serverPath) async {
    _emit('Downloading Fabric installer...', 0.5);
    try {
      const installerUrl =
          'https://maven.fabricmc.net/net/fabricmc/fabric-installer/1.0.1/fabric-installer-1.0.1.jar';

      final installerPath =
          '$serverPath/fabric-installer.jar';

      final dlOk = await PlatformService.downloadFile(
        url: installerUrl,
        destPath: installerPath,
        onStatus: (s) => _emit(s, 0.55),
      );

      if (!dlOk) {
        _emit('Fabric installer download failed', 0,
            done: true, success: false);
        return false;
      }

      _emit(
          'Running Fabric installer for $version...',
          0.7);

      final javaVer =
          PlatformService.javaVersionForMc(version);
      final javaHome =
          await PlatformService.getJavaHome(javaVer);

      final javaExec = Platform.isWindows
          ? '$javaHome/bin/java.exe'
              .replaceAll('\\', '/')
          : '$javaHome/bin/java';

      final serverPathFwd =
          serverPath.replaceAll('\\', '/');
      final installerPathFwd =
          installerPath.replaceAll('\\', '/');

      final installResult =
          await PlatformService.runCommand(
              'cd "$serverPathFwd" && '
              '"$javaExec" -jar "$installerPathFwd" '
              'server -mcversion $version '
              '-downloadMinecraft 2>&1');

      if (installResult.exitCode != 0) {
        _emit(
            'Fabric install failed: '
            '${installResult.stdout}'
            '${installResult.stderr}',
            0,
            done: true,
            success: false);
        return false;
      }

      // Create marker
      await File('$serverPath/.is_fabric')
          .writeAsString('');

      // Cleanup installer
      try {
        await File(installerPath).delete();
      } catch (_) {}

      return await _finalise(serverPath, version,
          type: 'Fabric');
    } catch (e) {
      _emit('Fabric error: $e', 0,
          done: true, success: false);
      return false;
    }
  }

  Future<bool> _downloadForge(
      String version, String serverPath) async {
    _emit('Fetching Forge for $version...', 0.5);
    try {
      final forgeMap = {
        '1.21.1': '47.3.0',
        '1.20.6': '50.1.0',
        '1.20.4': '49.1.0',
        '1.20.2': '48.1.0',
        '1.20.1': '47.3.0',
        '1.19.4': '45.3.0',
        '1.19.2': '43.3.0',
        '1.18.2': '40.2.0',
        '1.17.1': '37.1.1',
        '1.16.5': '36.2.39',
        '1.15.2': '31.2.57',
        '1.14.4': '28.2.26',
        '1.12.2': '14.23.5.2860',
      };

      final forgeVersion = forgeMap[version];
      if (forgeVersion == null) {
        _emit('Forge not available for $version',
            0, done: true, success: false);
        return false;
      }

      final installerUrl =
          'https://maven.minecraftforge.net/net/minecraftforge/forge/'
          '$version-$forgeVersion/'
          'forge-$version-$forgeVersion-installer.jar';

      final installerPath =
          '$serverPath/forge-installer.jar';

      _emit('Downloading Forge installer...', 0.55);
      final dlOk = await PlatformService.downloadFile(
        url: installerUrl,
        destPath: installerPath,
        onStatus: (s) => _emit(s, 0.6),
      );

      if (!dlOk) {
        _emit('Forge installer download failed', 0,
            done: true, success: false);
        return false;
      }

      _emit(
          'Running Forge installer '
          '(this takes a while)...',
          0.75);

      final javaVer =
          PlatformService.javaVersionForMc(version);
      final javaHome =
          await PlatformService.getJavaHome(javaVer);

      final javaExec = Platform.isWindows
          ? '$javaHome/bin/java.exe'
              .replaceAll('\\', '/')
          : '$javaHome/bin/java';

      final serverPathFwd =
          serverPath.replaceAll('\\', '/');
      final installerPathFwd =
          installerPath.replaceAll('\\', '/');

      final installResult =
          await PlatformService.runCommand(
              'cd "$serverPathFwd" && '
              '"$javaExec" -jar "$installerPathFwd" '
              '--installServer 2>&1');

      try {
        await File(installerPath).delete();
      } catch (_) {}

      if (installResult.exitCode != 0) {
        _emit('Forge install failed', 0,
            done: true, success: false);
        return false;
      }

      return await _finalise(serverPath, version,
          type: 'Forge');
    } catch (e) {
      _emit('Forge error: $e', 0,
          done: true, success: false);
      return false;
    }
  }

  Future<bool> _finalise(String serverPath,
      String version,
      {String type = 'Vanilla'}) async {
    _emit('Accepting EULA...', 0.9);
    try {
      final eulaPath = Platform.isWindows
          ? '$serverPath\\eula.txt'
          : '$serverPath/eula.txt';
      await File(eulaPath)
          .writeAsString('eula=true\n');
    } catch (e) {
      print('eula write error: $e');
    }
    _emit('$type $version server ready!', 1.0,
        done: true, success: true);
    return true;
  }

  static bool isVersionSupported(String version,
      {ServerType type = ServerType.vanilla}) {
    return true; // All versions supported via dynamic fetch
  }

  void dispose() {
    _progressController.close();
  }
}

class DownloadProgress {
  final String status;
  final double progress;
  final bool done;
  final bool success;

  DownloadProgress({
    required this.status,
    required this.progress,
    required this.done,
    required this.success,
  });
}