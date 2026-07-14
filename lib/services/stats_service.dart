import 'dart:io';
import 'dart:async';

class ServerStats {
  final double tps;
  final int ramUsedMb;
  final int ramTotalMb;
  final double cpuPercent;
  final double packetLoss;
  final int worldSizeMb;
  final int playersOnline;
  final int maxPlayers;
  final Duration uptime;
  final String version;

  const ServerStats({
    this.tps = 20.0,
    this.ramUsedMb = 0,
    this.ramTotalMb = 0,
    this.cpuPercent = 0,
    this.packetLoss = 0,
    this.worldSizeMb = 0,
    this.playersOnline = 0,
    this.maxPlayers = 20,
    this.uptime = Duration.zero,
    this.version = '?',
  });

  ServerStats copyWith({
    double? tps,
    int? ramUsedMb,
    int? ramTotalMb,
    double? cpuPercent,
    double? packetLoss,
    int? worldSizeMb,
    int? playersOnline,
    int? maxPlayers,
    Duration? uptime,
    String? version,
  }) {
    return ServerStats(
      tps: tps ?? this.tps,
      ramUsedMb: ramUsedMb ?? this.ramUsedMb,
      ramTotalMb: ramTotalMb ?? this.ramTotalMb,
      cpuPercent: cpuPercent ?? this.cpuPercent,
      packetLoss: packetLoss ?? this.packetLoss,
      worldSizeMb: worldSizeMb ?? this.worldSizeMb,
      playersOnline: playersOnline ?? this.playersOnline,
      maxPlayers: maxPlayers ?? this.maxPlayers,
      uptime: uptime ?? this.uptime,
      version: version ?? this.version,
    );
  }
}

class StatsService {
  Timer? _pollTimer;
  String? _serverPath;
  final _statsController =
      StreamController<ServerStats>.broadcast();
  ServerStats _current = const ServerStats();

  Stream<ServerStats> get stats => _statsController.stream;
  ServerStats get current => _current;

  void start({
    required String serverPath,
    required Function() onPollTick,
  }) {
    _serverPath = serverPath;
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) async {
        onPollTick(); // triggers 'list' command to get players
        await _pollSystemStats();
      },
    );
  }

  void stop() {
    _pollTimer?.cancel();
    _current = const ServerStats();
    _statsController.add(_current);
  }

  Future<void> _pollSystemStats() async {
    if (Platform.isAndroid) {
      await _pollSystemStatsAndroid();
    } else {
      await _pollSystemStatsWindows();
    }
  }

  // ── Android: read /proc directly, no WSL needed ──────────────────────────
  Future<void> _pollSystemStatsAndroid() async {
    try {
      // Find Java PID via pgrep (available on Android via /system/bin)
      final pidResult = await Process.run('/system/bin/sh', [
        '-c',
        'pgrep -f "server\\.jar\\|fabric-server-launch\\.jar" | head -1',
      ]);

      if (pidResult.exitCode != 0 ||
          pidResult.stdout.toString().trim().isEmpty) {
        // Server not running or pgrep unavailable — zero out
        _current = _current.copyWith(
          ramUsedMb: 0,
          cpuPercent: 0,
        );
        _statsController.add(_current);
        return;
      }

      final pid = pidResult.stdout.toString().trim();

      // ── RAM ──────────────────────────────────────────────────────────────
      int ramUsed = 0;
      try {
        final statusFile = File('/proc/$pid/status');
        if (await statusFile.exists()) {
          for (final line in (await statusFile.readAsString()).split('\n')) {
            if (line.startsWith('VmRSS:')) {
              final kb = int.tryParse(
                      line.replaceAll(RegExp(r'[^0-9]'), '')) ??
                  0;
              ramUsed = kb ~/ 1024;
              break;
            }
          }
        }
      } catch (_) {}

      // ── Total RAM ────────────────────────────────────────────────────────
      int ramTotal = 0;
      try {
        for (final line
            in (await File('/proc/meminfo').readAsString()).split('\n')) {
          if (line.startsWith('MemTotal:')) {
            final kb = int.tryParse(
                    line.replaceAll(RegExp(r'[^0-9]'), '')) ??
                0;
            ramTotal = kb ~/ 1024;
            break;
          }
        }
      } catch (_) {}

      // ── CPU: two-sample delta from /proc/[pid]/stat ──────────────────────
      double cpu = 0;
      try {
        final stat1 = await File('/proc/$pid/stat').readAsString();
        final sys1 =
            await File('/proc/stat').readAsLines().then((l) => l.first);
        await Future.delayed(const Duration(milliseconds: 300));
        final stat2 = await File('/proc/$pid/stat').readAsString();
        final sys2 =
            await File('/proc/stat').readAsLines().then((l) => l.first);

        final p1 = _parseProcStat2(stat1, sys1);
        final p2 = _parseProcStat2(stat2, sys2);
        if (p1 != null && p2 != null) {
          final procDelta =
              (p2['procTime']! - p1['procTime']!).toDouble();
          final totalDelta =
              (p2['totalTime']! - p1['totalTime']!).toDouble();
          if (totalDelta > 0) {
            // Don't divide by numCpus — Android rarely has separate per-core
            // process time; this gives a reasonable 0–100% single-core view.
            cpu = (procDelta / totalDelta * 100).clamp(0, 100);
          }
        }
      } catch (_) {}

      // ── World size ────────────────────────────────────────────────────────
      int worldSize = 0;
      if (_serverPath != null) {
        try {
          final worldDir = Directory('$_serverPath/world');
          if (await worldDir.exists()) {
            int bytes = 0;
            await for (final entity in worldDir.list(recursive: true)) {
              if (entity is File) bytes += await entity.length();
            }
            worldSize = bytes ~/ (1024 * 1024);
          }
        } catch (_) {}
      }

      _current = _current.copyWith(
        ramUsedMb: ramUsed,
        ramTotalMb: ramTotal,
        cpuPercent: cpu,
        worldSizeMb: worldSize,
        packetLoss: 0, // loopback ping always 0 on Android; skip the overhead
      );
      _statsController.add(_current);
    } catch (_) {}
  }

  Map<String, int>? _parseProcStat2(String pidStat, String cpuLine) {
    try {
      final pidFields = pidStat.trim().split(RegExp(r'\s+'));
      // utime=14 stime=15 cutime=16 cstime=17 (0-indexed)
      final procTime = int.parse(pidFields[13]) +
          int.parse(pidFields[14]) +
          int.parse(pidFields[15]) +
          int.parse(pidFields[16]);

      final cpuFields = cpuLine.trim().split(RegExp(r'\s+'));
      int totalTime = 0;
      for (int i = 1; i < cpuFields.length; i++) {
        totalTime += int.tryParse(cpuFields[i]) ?? 0;
      }
      return {'procTime': procTime, 'totalTime': totalTime};
    } catch (_) {
      return null;
    }
  }

  // ── Windows: existing WSL-based polling (unchanged) ──────────────────────
  Future<void> _pollSystemStatsWindows() async {
    try {
      final pidResult = await Process.run('wsl.exe', [
        '-e', 'bash', '-c',
        'pgrep -f "server.jar\\|fabric-server-launch.jar" | head -1',
      ]);
      if (pidResult.exitCode != 0 ||
          pidResult.stdout.toString().trim().isEmpty) return;

      final pid = pidResult.stdout.toString().trim();

      // CPU: two-sample delta
      final cpu1Result = await Process.run('wsl.exe', [
        '-e', 'bash', '-c',
        'cat /proc/$pid/stat 2>/dev/null && echo "---" && cat /proc/stat | head -1',
      ]);
      await Future.delayed(const Duration(milliseconds: 500));
      final cpu2Result = await Process.run('wsl.exe', [
        '-e', 'bash', '-c',
        'cat /proc/$pid/stat 2>/dev/null && echo "---" && cat /proc/stat | head -1',
      ]);

      double cpu = 0;
      int ramUsed = 0;
      int ramTotal = 0;

      if (cpu1Result.exitCode == 0 && cpu2Result.exitCode == 0) {
        try {
          final parse1 = _parseProcStat(cpu1Result.stdout.toString());
          final parse2 = _parseProcStat(cpu2Result.stdout.toString());
          if (parse1 != null && parse2 != null) {
            final procDelta =
                (parse2['procTime']! - parse1['procTime']!).toDouble();
            final totalDelta =
                (parse2['totalTime']! - parse1['totalTime']!).toDouble();
            if (totalDelta > 0) {
              final numCpu = _numCpus;
              cpu = ((procDelta / totalDelta) * 100 / numCpu).clamp(0, 100);
            }
          }
        } catch (_) {}
      }

      final ramResult = await Process.run('wsl.exe', [
        '-e', 'bash', '-c',
        'cat /proc/$pid/status 2>/dev/null | grep VmRSS ; free -m | grep "^Mem:"',
      ]);
      if (ramResult.exitCode == 0) {
        for (final line in ramResult.stdout.toString().split('\n')) {
          if (line.startsWith('VmRSS')) {
            final kb =
                int.tryParse(line.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
            ramUsed = kb ~/ 1024;
          } else if (line.startsWith('Mem:')) {
            final parts = line.trim().split(RegExp(r'\s+'));
            if (parts.length > 1) {
              ramTotal = int.tryParse(parts[1]) ?? 0;
            }
          }
        }
      }

      int worldSize = 0;
      if (_serverPath != null) {
        final sizeResult = await Process.run('wsl.exe', [
          '-e', 'bash', '-c',
          'du -sm "$_serverPath/world" 2>/dev/null | cut -f1',
        ]);
        if (sizeResult.exitCode == 0) {
          worldSize =
              int.tryParse(sizeResult.stdout.toString().trim()) ?? 0;
        }
      }

      double packetLoss = 0;
      final pingResult = await Process.run('wsl.exe', [
        '-e', 'bash', '-c',
        "ping -c 3 -W 1 127.0.0.1 2>/dev/null | "
            "awk -F'[, ]+' '/packet loss/{for(i=1;i<=NF;i++) if(\$i~/[0-9]+%/) {gsub(/%/, \"\", \$i); print \$i; exit}}'",
      ]);
      if (pingResult.exitCode == 0) {
        packetLoss =
            double.tryParse(pingResult.stdout.toString().trim()) ?? 0;
      }

      _current = _current.copyWith(
        ramUsedMb: ramUsed,
        ramTotalMb: ramTotal,
        cpuPercent: cpu,
        worldSizeMb: worldSize,
        packetLoss: packetLoss,
      );
      _statsController.add(_current);
    } catch (_) {}
  }

  Map<String, int>? _parseProcStat(String output) {
    try {
      final parts = output.split('---\n');
      if (parts.length < 2) return null;

      final pidFields = parts[0].trim().split(RegExp(r'\s+'));
      final procTime = int.parse(pidFields[13]) +
          int.parse(pidFields[14]) +
          int.parse(pidFields[15]) +
          int.parse(pidFields[16]);

      final cpuFields = parts[1].trim().split(RegExp(r'\s+'));
      int totalTime = 0;
      for (int i = 1; i < cpuFields.length; i++) {
        totalTime += int.tryParse(cpuFields[i]) ?? 0;
      }
      return {'procTime': procTime, 'totalTime': totalTime};
    } catch (_) {
      return null;
    }
  }

  int? _cachedNumCpus;
  int get _numCpus {
    if (_cachedNumCpus != null) return _cachedNumCpus!;
    try {
      final result = Process.runSync('wsl.exe', ['-e', 'bash', '-c', 'nproc']);
      _cachedNumCpus = int.tryParse(result.stdout.toString().trim()) ?? 1;
    } catch (_) {
      _cachedNumCpus = 1;
    }
    return _cachedNumCpus!;
  }

  void updateFromServerOutput({
    double? tps,
    int? playersOnline,
    int? maxPlayers,
    Duration? uptime,
    String? version,
    bool tpsFromServer = false,
  }) {
    _current = _current.copyWith(
      tps: tps,
      playersOnline: playersOnline,
      maxPlayers: maxPlayers,
      uptime: uptime,
      version: version,
    );
    _statsController.add(_current);
  }

  void dispose() {
    _pollTimer?.cancel();
    _statsController.close();
  }
}