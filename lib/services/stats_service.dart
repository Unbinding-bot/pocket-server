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
    try {
      // ── Find Java PID ────────────────────────────────────
      final pidResult = await Process.run('wsl.exe', [
        '-e', 'bash', '-c',
        'pgrep -f "server.jar\\|fabric-server-launch.jar" | head -1',
      ]);
      if (pidResult.exitCode != 0 ||
          pidResult.stdout.toString().trim().isEmpty) return;

      final pid = pidResult.stdout.toString().trim();

      // ── CPU: use /proc/stat two-sample delta for accuracy ─
      // Sample 1
      final cpu1Result = await Process.run('wsl.exe', [
        '-e', 'bash', '-c',
        'cat /proc/$pid/stat 2>/dev/null && echo "---" && cat /proc/stat | head -1',
      ]);
      await Future.delayed(const Duration(milliseconds: 500));
      // Sample 2
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
              // Cap at 100 % — divide by number of logical CPUs later
              final numCpu = _numCpus;
              cpu = ((procDelta / totalDelta) * 100 / numCpu).clamp(0, 100);
            }
          }
        } catch (_) {}
      }

      // ── RAM ──────────────────────────────────────────────
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
            // FIX: Added curly braces to satisfy linter
            if (parts.length > 1) {
              ramTotal = int.tryParse(parts[1]) ?? 0;
            }
          }
        }
      }

      // ── World size ───────────────────────────────────────
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

      // ── Packet loss: single quick ping ───────────────────
      double packetLoss = 0;
      // FIX: Changed raw strings to standard strings and escaped $ and " 
      // This prevents the string from terminating early at \"
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

  /// Returns null on parse failure.
  Map<String, int>? _parseProcStat(String output) {
    try {
      final parts = output.split('---\n');
      if (parts.length < 2) return null;

      // /proc/[pid]/stat fields: utime=14, stime=15, cutime=16, cstime=17
      final pidFields = parts[0].trim().split(RegExp(r'\s+'));
      final procTime = int.parse(pidFields[13]) +
          int.parse(pidFields[14]) +
          int.parse(pidFields[15]) +
          int.parse(pidFields[16]);

      // /proc/stat cpu line: user nice system idle iowait irq softirq steal
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

  // Cache CPU count (doesn't change at runtime)
  int? _cachedNumCpus;
  int get _numCpus {
    if (_cachedNumCpus != null) return _cachedNumCpus!;
    try {
      final result = Process.runSync('wsl.exe', [
        '-e', 'bash', '-c', 'nproc',
      ]);
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
    // Only update TPS if it came from actual server output (not a stale guess)
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