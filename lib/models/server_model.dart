import 'dart:convert';
import 'server_properties.dart';
import '../services/java_downloader.dart';

class ServerModel {
  final String id;
  final String name;
  final String path;
  final int ramMb;
  final String version;
  final ServerType serverType;
  final DateTime? lastPlayed;
  final List<String> mods;
  final ServerProperties properties;

  ServerModel({
    required this.id,
    required this.name,
    required this.path,
    required this.ramMb,
    required this.version,
    this.serverType = ServerType.vanilla,
    this.lastPlayed,
    this.mods = const [],
    ServerProperties? properties,
  }) : properties = properties ?? ServerProperties();

  ServerModel copyWith({
    String? name,
    String? path,
    int? ramMb,
    String? version,
    ServerType? serverType,
    DateTime? lastPlayed,
    List<String>? mods,
    ServerProperties? properties,
  }) {
    return ServerModel(
      id: id,
      name: name ?? this.name,
      path: path ?? this.path,
      ramMb: ramMb ?? this.ramMb,
      version: version ?? this.version,
      serverType: serverType ?? this.serverType,
      lastPlayed: lastPlayed ?? this.lastPlayed,
      mods: mods ?? this.mods,
      properties: properties ?? this.properties,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'path': path,
        'ramMb': ramMb,
        'version': version,
        'serverType': serverType.name,
        'lastPlayed': lastPlayed?.toIso8601String(),
        'mods': mods,
        'properties': properties.toJson(),
      };

  factory ServerModel.fromJson(Map<String, dynamic> json) {
    ServerType type = ServerType.vanilla;
    try {
      type = ServerType.values.firstWhere(
        (e) => e.name == json['serverType'],
        orElse: () => ServerType.vanilla,
      );
    } catch (_) {}

    return ServerModel(
      id: json['id'],
      name: json['name'],
      path: json['path'],
      ramMb: json['ramMb'],
      version: json['version'],
      serverType: type,
      lastPlayed: json['lastPlayed'] != null
          ? DateTime.parse(json['lastPlayed'])
          : null,
      mods: List<String>.from(json['mods'] ?? []),
      properties: json['properties'] != null
          ? ServerProperties.fromJson(json['properties'])
          : ServerProperties(),
    );
  }

  String toJsonString() => jsonEncode(toJson());
  factory ServerModel.fromJsonString(String s) =>
      ServerModel.fromJson(jsonDecode(s));
}