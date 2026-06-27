import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'server_model.dart';

class AppState extends ChangeNotifier {
  List<ServerModel> _servers = [];
  ServerModel? _activeServer;

  List<ServerModel> get servers => _servers;
  ServerModel? get activeServer => _activeServer;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final serverList = prefs.getStringList('servers') ?? [];
    
    _servers = serverList
        .map((s) => ServerModel.fromJsonString(s))
        .toList();

    final activeId = prefs.getString('activeServerId');
    
    // Fix: Instead of throwing an exception, check if the server exists
    if (activeId != null && _servers.isNotEmpty) {
      try {
        _activeServer = _servers.firstWhere(
          (s) => s.id == activeId,
          orElse: () => _servers.first,
        );
      } catch (_) {
        _activeServer = _servers.first;
      }
    } else if (_servers.isNotEmpty) {
      // If no active ID but we have servers, pick the first one
      _activeServer = _servers.first;
    } else {
      // If no servers exist at all, keep it null so the UI can show setup
      _activeServer = null;
    }
    
    notifyListeners();
  }

  Future<void> addServer(ServerModel server) async {
    _servers.add(server);
    await _save();
    notifyListeners();
  }

  Future<void> setActiveServer(ServerModel server) async {
    _activeServer = server;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('activeServerId', server.id);
    notifyListeners();
  }

  Future<void> removeServer(String id) async {
    _servers.removeWhere((s) => s.id == id);
    if (_activeServer?.id == id) {
      _activeServer = _servers.isNotEmpty ? _servers.first : null;
    }
    await _save();
    notifyListeners();
  }
  
  Future<void> updateServer(ServerModel server) async {
    final index = _servers.indexWhere((s) => s.id == server.id);
    if (index == -1) return;
    _servers[index] = server;
    if (_activeServer?.id == server.id) _activeServer = server;
    await _save();
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'servers',
      _servers.map((s) => s.toJsonString()).toList(),
    );
  }
  String? _runningServerId;
  String? get runningServerId => _runningServerId;

  void setRunning(String? id) {
    _runningServerId = id;
    notifyListeners();
  }

  Future<void> updateLastPlayed(String id) async {
    final index = _servers.indexWhere((s) => s.id == id);
    if (index == -1) return;
    _servers[index] = _servers[index].copyWith(lastPlayed: DateTime.now());
    await _save();
    notifyListeners();
  }
}