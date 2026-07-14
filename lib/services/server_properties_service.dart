import 'dart:io';
import '../models/server_properties.dart';
import 'platform_service.dart';

class ServerPropertiesService {
  // Write server.properties to the server folder.
  // Previously used wsl.exe which breaks on Android.
  // Now uses Dart's File API directly — works everywhere.
  Future<bool> apply({
    required String serverPath,
    required ServerProperties properties,
  }) async {
    try {
      final propertiesPath = Platform.isWindows
          ? '$serverPath\\server.properties'
          : '$serverPath/server.properties';
      await File(propertiesPath)
          .writeAsString(properties.toPropertiesFile());
      return true;
    } catch (e) {
      print('ServerPropertiesService.apply error: $e');
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

  // Read existing server.properties.
  // Previously used wsl.exe — now uses Dart File API.
  Future<ServerProperties?> read(String serverPath) async {
    try {
      final propertiesPath = Platform.isWindows
          ? '$serverPath\\server.properties'
          : '$serverPath/server.properties';
      final file = File(propertiesPath);
      if (!await file.exists()) return null;
      final content = await file.readAsString();
      return ServerProperties.fromPropertiesFile(content);
    } catch (_) {
      return null;
    }
  }

  Future<String> getNativePath(String serverPath) async {
    return PlatformService.toNativePath(serverPath);
  }
}