import 'dart:io';
import '../models/server_properties.dart';
import 'platform_service.dart';

class ServerPropertiesService {
  // Write server.properties to the server folder
  Future<bool> apply({
    required String serverPath,
    required ServerProperties properties,
  }) async {
    try {
      // Write server.properties
      final content = properties.toPropertiesFile();
      final result = await Process.run(
        'wsl.exe',
        [
          '-e', 'bash', '-c',
          'cat > "$serverPath/server.properties" << \'PROPS\'\n${content}PROPS',
        ],
      );

      if (result.exitCode != 0) {
        // Fallback: write via echo
        await Process.run('wsl.exe', [
          '-e', 'bash', '-c',
          'printf "%s" ${_escapeShell(content)} > "$serverPath/server.properties"',
        ]);
      }

      return true;
    } catch (e) {
      return false;
    }
  }

  // Apply gamerules via server commands (while server is running)
  List<String> getGameruleCommands(ServerProperties properties) {
    return [
      'gamerule doWeatherCycle ${properties.rain}',
      'gamerule mobGriefing ${properties.mobGriefing}',
      'gamerule randomTickSpeed ${properties.randomTickSpeed}',
      'gamerule doMobSpawning ${properties.spawnMonsters}',
    ];
  }

  String _escapeShell(String input) {
    return "'${input.replaceAll("'", "'\\''")}'";
  }

  // Read existing server.properties
  Future<ServerProperties?> read(String serverPath) async {
    try {
      final result = await Process.run(
        'wsl.exe',
        ['-e', 'bash', '-c', 'cat "$serverPath/server.properties"'],
      );
      if (result.exitCode == 0) {
        return ServerProperties.fromPropertiesFile(
            result.stdout.toString());
      }
      return null;
    } catch (_) {
      return null;
    }
  }
  Future<String> getNativePath(
      String serverPath) async {
    return PlatformService.toNativePath(serverPath);
  }
}