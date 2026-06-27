import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'platform_service.dart';

class TermuxEnvService {
  static const _channel =
      MethodChannel('com.example.pocket_server/setup');

  static String? _prefix;

  // The "prefix" is where our Termux env lives
  static Future<String> getPrefix() async {
    if (_prefix != null) return _prefix!;
    final base =
        await PlatformService.getAppFilesPath();
    _prefix = p.join(base, 'termux');
    return _prefix!;
  }

  static Future<String> getBinPath() async {
    return p.join(await getPrefix(), 'usr', 'bin');
  }

  static Future<String> getJavaHome() async {
    return p.join(
        await getPrefix(), 'usr', 'lib', 'jvm',
        'java-17-openjdk');
  }

  static Future<bool> isInstalled() async {
    if (!Platform.isAndroid) return true;
    final prefix = await getPrefix();
    final sh = File(p.join(prefix, 'usr', 'bin', 'sh'));
    return sh.existsSync();
  }

  static Future<bool> isJavaInstalled() async {
    if (!Platform.isAndroid) return true;
    final javaHome = await getJavaHome();
    // Try common Termux java locations
    final locations = [
      p.join(javaHome, 'bin', 'java'),
      p.join(await getPrefix(), 'usr', 'bin', 'java'),
    ];
    return locations.any((f) => File(f).existsSync());
  }

  // Get environment variables for running commands
  static Future<Map<String, String>> getEnv() async {
    final prefix = await getPrefix();
    final usr = p.join(prefix, 'usr');
    final bin = p.join(usr, 'bin');
    final lib = p.join(usr, 'lib');

    return {
      'PREFIX': usr,
      'HOME': prefix,
      'TMPDIR': p.join(prefix, 'tmp'),
      'PATH': '$bin:/system/bin:/system/xbin',
      'LD_LIBRARY_PATH': lib,
      'LANG': 'en_US.UTF-8',
    };
  }

  // Get java-specific env
  static Future<Map<String, String>> getJavaEnv() async {
    final env = await getEnv();
    final javaHome = await getJavaHome();
    final prefix = await getPrefix();
    final usr = p.join(prefix, 'usr');
    final lib = p.join(usr, 'lib');

    // Find actual java binary
    String actualJavaHome = javaHome;
    if (!File(p.join(javaHome, 'bin', 'java'))
        .existsSync()) {
      // Try to find java in usr/bin
      final javaLink =
          File(p.join(usr, 'bin', 'java'));
      if (javaLink.existsSync()) {
        actualJavaHome = usr;
      }
    }

    env['JAVA_HOME'] = actualJavaHome;
    env['LD_LIBRARY_PATH'] =
        '$lib:${p.join(actualJavaHome, 'lib')}:'
        '${p.join(actualJavaHome, 'lib', 'server')}';
    return env;
  }

  // Run a command in our Termux environment
  static Future<ProcessResult> runCommand(
      String command) async {
    if (!Platform.isAndroid) {
      return PlatformService.runCommand(command);
    }

    final env = await getEnv();
    final result = await _channel.invokeMethod<String>(
      'runCommand',
      {'cmd': command, 'env': env},
    );
    return ProcessResult(0, 0, result ?? '', '');
  }

  // Setup: extract bootstrap + install Java
  static Future<bool> setup(
      Function(String, double) onProgress) async {
    if (!Platform.isAndroid) return true;

    final prefix = await getPrefix();

    // Step 1: Extract Termux bootstrap
    onProgress('Extracting environment...', 0.1);
    await Directory(prefix).create(recursive: true);

    try {
      await _channel.invokeMethod('extractBootstrap', {
        'destDir': p.join(prefix, 'usr'),
      });
    } catch (e) {
      // Bootstrap zip extracts to different structure
      // Try extracting to prefix directly
      await _channel.invokeMethod('extractBootstrap', {
        'destDir': prefix,
      });
    }

    onProgress('Setting up directories...', 0.3);

    // Create essential dirs
    for (final dir in [
      'tmp', 'home', 'usr/bin', 'usr/lib',
      'usr/lib/jvm',
    ]) {
      await Directory(p.join(prefix, dir))
          .create(recursive: true);
    }

    // Make binaries executable
    await _channel.invokeMethod('runCommand', {
      'cmd': 'chmod -R 755 ${p.join(prefix, 'usr', 'bin')} 2>/dev/null || true',
      'env': await getEnv(),
    });

    onProgress('Installing Java 17...', 0.4);

    // Step 2: Extract the OpenJDK deb
    // First copy it out of assets
    final tempDir = p.join(prefix, 'tmp');
    await Directory(tempDir).create(recursive: true);

    try {
      await _channel.invokeMethod('extractDeb', {
        'asset': 'tools/android/openjdk-17.deb',
        'destDir': p.join(prefix, 'usr'),
      });
      onProgress('Java 17 installed!', 0.8);
    } catch (e) {
      onProgress('Deb extraction failed: $e — trying fallback...', 0.5);
      // Fallback: download Java directly
      final ok = await _downloadJavaFallback(
          prefix, onProgress);
      if (!ok) return false;
    }

    // Fix permissions on java binaries
    onProgress('Fixing permissions...', 0.9);
    final javaBin =
        p.join(prefix, 'usr', 'bin', 'java');
    final javaLibDir =
        p.join(prefix, 'usr', 'lib', 'jvm');

    await _channel.invokeMethod('runCommand', {
      'cmd': 'chmod -R 755 "$javaLibDir" 2>/dev/null; '
          'chmod 755 "$javaBin" 2>/dev/null; '
          'true',
      'env': await getEnv(),
    });

    // Verify java works
    onProgress('Verifying Java...', 0.95);
    final verify = await _channel
        .invokeMethod<String>('runCommand', {
      'cmd': 'java -version 2>&1 || '
          '${p.join(prefix, 'usr', 'bin', 'java')} '
          '-version 2>&1',
      'env': await (getJavaEnv()),
    });
    print('Java verify: $verify');

    onProgress('Setup complete!', 1.0);
    return true;
  }

  static Future<bool> _downloadJavaFallback(
      String prefix,
      Function(String, double) onProgress) async {
    // Download Termux's Java package directly
    const url =
        'https://packages.termux.dev/apt/termux-main/'
        'pool/main/o/openjdk-17/'
        'openjdk-17_17.0.18_aarch64.deb';

    onProgress('Downloading Java 17...', 0.5);

    final tempDeb =
        p.join(prefix, 'tmp', 'openjdk-17.deb');

    final ok = await PlatformService.downloadFile(
      url: url,
      destPath: tempDeb,
      onStatus: (s) => onProgress(s, 0.6),
    );

    if (!ok) return false;

    onProgress('Extracting Java...', 0.75);
    await _channel.invokeMethod('extractDeb', {
      'asset': '',
      'destDir': p.join(prefix, 'usr'),
    });

    return true;
  }

  static Future<bool> isJava21Installed() async {
    if (!Platform.isAndroid) return true;
    final prefix = await getPrefix();
    final locations = [
      p.join(prefix, 'usr', 'lib', 'jvm',
          'java-21-openjdk', 'bin', 'java'),
      p.join(prefix, 'usr', 'bin', 'java21'),
    ];
    return locations.any((f) => File(f).existsSync());
  }

  static Future<String> getJava21Home() async {
    final prefix = await getPrefix();
    return p.join(
        prefix, 'usr', 'lib', 'jvm',
        'java-21-openjdk');
  }

  //java8 shit
  static Future<String> getJava8Home() async {
    final prefix = await getPrefix();
    return p.join(
        prefix, 'usr', 'lib', 'jvm',
        'java-8-openjdk');
  }

  static Future<bool> isJava8Installed() async {
    if (!Platform.isAndroid) return true;
    final javaHome = await getJava8Home();
    return File(p.join(javaHome, 'bin', 'java'))
        .existsSync();
  }

  static Future<bool> ensureJava8(
      Function(String) onStatus) async {
    if (await isJava8Installed()) return true;

    onStatus('Installing Java 8...');
    final prefix = await getPrefix();

    try {
      await _channel.invokeMethod('extractDeb', {
        'asset': 'tools/android/openjdk-8.deb',
        'destDir': p.join(prefix, 'usr'),
      });

      final javaHome = await getJava8Home();
      await _channel.invokeMethod('runCommand', {
        'cmd':
            'chmod -R 755 "$javaHome" 2>/dev/null; true',
        'env': await getEnv(),
      });

      onStatus('Java 8 installed!');
      return true;
    } catch (e) {
      onStatus('Java 8 install failed: $e');
      return false;
    }
  }

  // Get env for a specific java version
  static Future<Map<String, String>> getJavaEnvForVersion(
      int version) async {
    final env = await getEnv();
    final prefix = await getPrefix();
    final usr = p.join(prefix, 'usr');

    String javaHome;
    if (version >= 21) {
      javaHome = await getJava21Home();
    } else if (version >= 17) {
      javaHome = await getJavaHome();
    } else {
      javaHome = await getJava8Home();
    }

    env['JAVA_HOME'] = javaHome;
    env['LD_LIBRARY_PATH'] =
        '${p.join(usr, 'lib')}:'
        '${p.join(javaHome, 'lib')}:'
        '${p.join(javaHome, 'lib', 'server')}';
    return env;
  }

  // Install Java 21 lazily
  static Future<bool> ensureJava21(
      Function(String) onStatus) async {
    if (await isJava21Installed()) return true;

    onStatus('Installing Java 21...');
    final prefix = await getPrefix();

    try {
      await _channel.invokeMethod('extractDeb', {
        'asset': 'tools/android/openjdk-21.deb',
        'destDir': p.join(prefix, 'usr'),
      });

      // Fix permissions
      final javaHome = await getJava21Home();
      await _channel.invokeMethod('runCommand', {
        'cmd': 'chmod -R 755 "$javaHome" 2>/dev/null; true',
        'env': await getEnv(),
      });

      onStatus('Java 21 installed!');
      return true;
    } catch (e) {
      onStatus('Java 21 install failed: $e');
      return false;
    }
  }

  // Start server with correct Java version
  static Future<Process> startServer({
    required String serverPath,
    required int ramMb,
    required String serverJar,
    int javaVersion = 17,
  }) async {
    final prefix = await getPrefix();

    // Ensure correct java is installed
    if (javaVersion >= 21 &&
        !await isJava21Installed()) {
      await ensureJava21((_) {});
    } else if (javaVersion <= 8 &&
        !await isJava8Installed()) {
      await ensureJava8((_) {});
    }

    final env =
        await getJavaEnvForVersion(javaVersion);

    final java8Home  = await getJava8Home();
    final java17Home = await getJavaHome();
    final java21Home = await getJava21Home();

    final List<String> candidates;
    if (javaVersion >= 21) {
      candidates = [
        p.join(java21Home, 'bin', 'java'),
        p.join(prefix, 'usr', 'bin', 'java'),
      ];
    } else if (javaVersion >= 17) {
      candidates = [
        p.join(java17Home, 'bin', 'java'),
        p.join(prefix, 'usr', 'bin', 'java'),
      ];
    } else {
      candidates = [
        p.join(java8Home, 'bin', 'java'),
        p.join(prefix, 'usr', 'bin', 'java'),
      ];
    }

    String javaBin = '/system/bin/sh';
    for (final c in candidates) {
      if (File(c).existsSync()) {
        javaBin = c;
        break;
      }
    }

    final xmx = '${ramMb}M';
    final xms = '${ramMb ~/ 2}M';
    final cmd = '"$javaBin" '
        '-Xmx$xmx -Xms$xms '
        '-jar "$serverPath/$serverJar" nogui';

    return Process.start(
      '/system/bin/sh',
      ['-c', cmd],
      workingDirectory: serverPath,
      environment: env,
    );
  }
}

class ProcessBuilder {
  final String workDir;
  final String cmd;
  final Map<String, String> env;

  ProcessBuilder(this.workDir, this.cmd, this.env);

  Future<Process> start() async {
    return Process.start(
      '/system/bin/sh',
      ['-c', cmd],
      workingDirectory: workDir,
      environment: env,
    );
  }
  
}