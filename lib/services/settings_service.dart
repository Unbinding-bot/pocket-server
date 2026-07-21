import 'package:shared_preferences/shared_preferences.dart';
import 'tunnel_service.dart';

/// Central place for every persisted app setting. Two layers:
///
/// 1. Generic typed accessors (getString/setBool/etc.) — these exist so
///    adding a brand new setting anywhere in the app is a one-line call,
///    no new class or file needed:
///       final v = settings.getBool('my_new_toggle', false);
///       await settings.setBool('my_new_toggle', true);
///
/// 2. Named convenience getters/setters for settings the app already
///    knows about (tunnel provider, frp config, ...) — these just wrap
///    the generic layer with a proper type and a sensible default, so
///    call sites read naturally instead of scattering raw string keys
///    everywhere. Adding one of these for a new setting is optional and
///    just a small copy-paste of the pattern below; the generic layer
///    always works even without it.
///
/// Usage: `final settings = await SettingsService.getInstance();` once,
/// early in app startup (or per-screen, it's cheap — SharedPreferences
/// itself caches after first load), then read/write through it.
class SettingsService {
  static SettingsService? _instance;
  late final SharedPreferences _prefs;

  SettingsService._();

  static Future<SettingsService> getInstance() async {
    if (_instance != null) return _instance!;
    final service = SettingsService._();
    service._prefs = await SharedPreferences.getInstance();
    _instance = service;
    return service;
  }

  // ── Generic layer — use these directly for anything new ──────────
  String getString(String key, [String defaultValue = '']) =>
      _prefs.getString(key) ?? defaultValue;
  Future<void> setString(String key, String value) =>
      _prefs.setString(key, value);

  int getInt(String key, [int defaultValue = 0]) =>
      _prefs.getInt(key) ?? defaultValue;
  Future<void> setInt(String key, int value) => _prefs.setInt(key, value);

  bool getBool(String key, [bool defaultValue = false]) =>
      _prefs.getBool(key) ?? defaultValue;
  Future<void> setBool(String key, bool value) => _prefs.setBool(key, value);

  double getDouble(String key, [double defaultValue = 0]) =>
      _prefs.getDouble(key) ?? defaultValue;
  Future<void> setDouble(String key, double value) =>
      _prefs.setDouble(key, value);

  List<String> getStringList(String key, [List<String>? defaultValue]) =>
      _prefs.getStringList(key) ?? defaultValue ?? const [];
  Future<void> setStringList(String key, List<String> value) =>
      _prefs.setStringList(key, value);

  Future<void> remove(String key) => _prefs.remove(key);

  // ── Tunnel settings ────────────────────────────────────────────
  TunnelProviderType get tunnelProvider {
    final name = getString('tunnel_provider', TunnelProviderType.playit.name);
    return TunnelProviderType.values.firstWhere(
      (t) => t.name == name,
      orElse: () => TunnelProviderType.playit,
    );
  }

  Future<void> setTunnelProvider(TunnelProviderType type) =>
      setString('tunnel_provider', type.name);

  String get tunnelAddress => getString('tunnel_address');
  Future<void> setTunnelAddress(String v) => setString('tunnel_address', v);

  String get frpServerAddr => getString('frp_server_addr');
  Future<void> setFrpServerAddr(String v) => setString('frp_server_addr', v);

  int get frpServerPort => getInt('frp_server_port', 7000);
  Future<void> setFrpServerPort(int v) => setInt('frp_server_port', v);

  String get frpToken => getString('frp_token');
  Future<void> setFrpToken(String v) => setString('frp_token', v);

  int get frpRemotePort => getInt('frp_remote_port', 25565);
  Future<void> setFrpRemotePort(int v) => setInt('frp_remote_port', v);

  /// Saves all four frp fields in one write instead of four separate
  /// SharedPreferences calls.
  Future<void> setFrpConfig({
    required String serverAddr,
    required int serverPort,
    required String authToken,
    required int remotePort,
  }) async {
    await Future.wait([
      setFrpServerAddr(serverAddr),
      setFrpServerPort(serverPort),
      setFrpToken(authToken),
      setFrpRemotePort(remotePort),
    ]);
  }
}