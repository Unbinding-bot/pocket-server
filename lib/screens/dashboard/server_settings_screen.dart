import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import '../../models/server_model.dart';
import '../../models/server_properties.dart';
import '../../services/server_properties_service.dart';

class ServerSettingsScreen extends StatefulWidget {
  final ServerModel server;
  final Function(ServerModel) onSaved;
  final bool serverIsRunning;
  final Function(String) onSendCommand;

  const ServerSettingsScreen({
    super.key,
    required this.server,
    required this.onSaved,
    required this.serverIsRunning,
    required this.onSendCommand,
  });

  @override
  State<ServerSettingsScreen> createState() => _ServerSettingsScreenState();
}

class _ServerSettingsScreenState extends State<ServerSettingsScreen> {
  late ServerProperties _props;
  final _service = ServerPropertiesService();
  bool _saving = false;
  bool _advancedExpanded = false;

  // Controllers for text fields
  late TextEditingController _seedController;
  late TextEditingController _motdController;
  late TextEditingController _maxPlayersController;
  late TextEditingController _portController;
  late TextEditingController _tickSpeedController;

  List<String> _whitelistPlayers = [];
  final _whitelistController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _props = widget.server.properties;
    _seedController = TextEditingController(text: _props.seed);
    _motdController = TextEditingController(text: _props.motd);
    _maxPlayersController =
        TextEditingController(text: _props.maxPlayers.toString());
    _portController =
        TextEditingController(text: _props.serverPort.toString());
    _tickSpeedController =
        TextEditingController(text: _props.randomTickSpeed.toString());
    _loadWhitelist();
  }

  @override
  void dispose() {
    _seedController.dispose();
    _motdController.dispose();
    _maxPlayersController.dispose();
    _portController.dispose();
    _tickSpeedController.dispose();
    _whitelistController.dispose(); 
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);

    _props.seed = _seedController.text;
    _props.motd = _motdController.text;
    _props.maxPlayers =
        int.tryParse(_maxPlayersController.text) ??
            20;
    _props.serverPort =
        int.tryParse(_portController.text) ?? 25565;
    _props.randomTickSpeed =
        int.tryParse(_tickSpeedController.text) ?? 3;

    // Save server.properties
    await _service.apply(
      serverPath: widget.server.path,
      properties: _props,
    );

    // Save whitelist
    if (_props.whitelist) {
      await _saveWhitelist();
    }

    // Apply live gamerules if server is running
    final liveCommands = <String>[];
    if (widget.serverIsRunning) {
      liveCommands
          .addAll(_service.getGameruleCommands(_props));

      // Whitelist live commands
      if (_props.whitelist) {
        liveCommands.add('whitelist on');
        liveCommands.add('whitelist reload');
        for (final player in _whitelistPlayers) {
          liveCommands
              .add('whitelist add $player');
        }
      } else {
        liveCommands.add('whitelist off');
      }

      for (final cmd in liveCommands) {
        widget.onSendCommand(cmd);
      }
    }

    // Detect settings that require restart
    final restartRequired = _requiresRestart();

    final updated =
        widget.server.copyWith(properties: _props);
    widget.onSaved(updated);

    setState(() => _saving = false);

    if (mounted) {
      if (restartRequired &&
          widget.serverIsRunning) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Some settings require a server restart to take effect.',
            ),
            action: SnackBarAction(
              label: 'Restart',
              onPressed: () {
                widget.onSendCommand('stop');
              },
            ),
            duration: const Duration(seconds: 5),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Settings saved and applied!'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  bool _requiresRestart() {
    // These settings need a full restart
    final original = widget.server.properties;
    return original.gamemode != _props.gamemode ||
        original.hardcore != _props.hardcore ||
        original.worldType != _props.worldType ||
        original.seed != _props.seed ||
        original.serverPort != _props.serverPort ||
        original.onlineMode != _props.onlineMode ||
        original.forceGamemode !=
            _props.forceGamemode;
  }
  
  Future<void> _loadWhitelist() async {
    try {
      final nativePath =
          await ServerPropertiesService()
              .getNativePath(widget.server.path);
      final file = File(
          '$nativePath${Platform.isWindows ? '\\' : '/'}whitelist.json');
      if (await file.exists()) {
        final content = jsonDecode(
            await file.readAsString()) as List;
        setState(() {
          _whitelistPlayers = content
              .map((e) => e['name'] as String)
              .toList();
        });
      }
    } catch (_) {}
  }

  Future<void> _saveWhitelist() async {
    try {
      final nativePath =
          await ServerPropertiesService()
              .getNativePath(widget.server.path);
      final content = _whitelistPlayers
          .map((name) => {
                'uuid': '',
                'name': name,
              })
          .toList();
      final file = File(
          '$nativePath${Platform.isWindows ? '\\' : '/'}whitelist.json');
      await file.writeAsString(
          jsonEncode(content));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.server.name} Settings'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.black),
                    )
                  : const Icon(Icons.save, size: 18),
              label: const Text('Save'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF00C853),
                foregroundColor: Colors.black,
              ),
            ),
          ),
        ],
      ),
      
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.serverIsRunning)
            _warningBanner(
              'Server is running. Some changes require a restart.',
              Colors.orange,
            ),

          // ── Basic Settings ────────────────────────────────
          _sectionHeader('Basic'),
          _card(children: [
            // Online mode
            _switchTile(
              title: 'Online mode',
              subtitle: 'Off = allow cracked accounts',
              value: _props.onlineMode,
              onChanged: (v) => setState(() => _props.onlineMode = v),
              icon: Icons.verified_user,
              iconColor: _props.onlineMode ? Colors.green : Colors.red,
            ),
            _divider(),
            // Hardcore
            _switchTile(
              title: 'Hardcore mode',
              subtitle: 'Players are banned on death',
              value: _props.hardcore,
              onChanged: (v) => setState(() => _props.hardcore = v),
              icon: Icons.favorite,
              iconColor: Colors.red,
            ),
            _divider(),
            // PvP
            _switchTile(
              title: 'PvP',
              subtitle: 'Allow player vs player combat',
              value: _props.pvp,
              onChanged: (v) => setState(() => _props.pvp = v),
              icon: Icons.sports_kabaddi,
              iconColor: Colors.orange,
            ),
            _divider(),
            // Whitelist
            _switchTile(
              title: 'Whitelist',
              subtitle: 'Only allow listed players',
              value: _props.whitelist,
              onChanged: (v) => setState(() => _props.whitelist = v),
              icon: Icons.list,
              iconColor: Colors.blue,
            ),
          ]),

          // ── Whitelist ─────────────────────────────
          if (_props.whitelist) ...[
            const SizedBox(height: 16),
            _sectionHeader('Whitelist players'),
            _card(children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller:
                                _whitelistController,
                            decoration: InputDecoration(
                              hintText:
                                  'Player username',
                              filled: true,
                              fillColor: const Color(
                                  0xFF0D0D0D),
                              border:
                                  OutlineInputBorder(
                                borderRadius:
                                    BorderRadius
                                        .circular(8),
                                borderSide:
                                    BorderSide.none,
                              ),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () {
                            final name =
                                _whitelistController
                                    .text
                                    .trim();
                            if (name.isNotEmpty &&
                                !_whitelistPlayers
                                    .contains(name)) {
                              setState(() {
                                _whitelistPlayers
                                    .add(name);
                                _whitelistController
                                    .clear();
                              });
                            }
                          },
                          style:
                              FilledButton.styleFrom(
                            backgroundColor:
                                const Color(
                                    0xFF00C853),
                            foregroundColor:
                                Colors.black,
                          ),
                          child:
                              const Text('Add'),
                        ),
                      ],
                    ),
                    if (_whitelistPlayers
                        .isNotEmpty) ...[
                      const SizedBox(height: 12),
                      ..._whitelistPlayers
                          .asMap()
                         .entries
                          .map((entry) => Container(
                                key: ValueKey(
                                    'wl_${entry.value}_${entry.key}'),
                                margin: const EdgeInsets
                                    .only(bottom: 6),
                                padding:
                                    const EdgeInsets
                                        .symmetric(
                                        horizontal: 12,
                                        vertical: 8),
                                decoration: BoxDecoration(
                                  color: const Color(
                                      0xFF0D0D0D),
                                  borderRadius:
                                      BorderRadius
                                          .circular(8),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(
                                        Icons.person,
                                        size: 16,
                                        color:
                                            Colors.grey),
                                    const SizedBox(
                                        width: 8),
                                    Expanded(
                                     child: Text(
                                       entry.value,
                                        style: const TextStyle(
                                            fontSize: 13),
                                      ),
                                    ),
                                    GestureDetector(
                                      onTap: () =>
                                          setState(() {
                                        _whitelistPlayers
                                            .removeAt(
                                                entry.key);
                                      }),
                                      child: const Icon(
                                          Icons.close,
                                          size: 14,
                                          color:
                                              Colors.red),
                                    ),
                                  ],
                                ),
                              )),
                    ],
                  ],
                ),
              ),
            ]),
          ],    

          const SizedBox(height: 16),

          // ── Gameplay ──────────────────────────────────────
          _sectionHeader('Gameplay'),
          _card(children: [
            // Difficulty
            _dropdownTile(
              title: 'Difficulty',
              icon: Icons.shield,
              value: _props.difficulty,
              items: const ['peaceful', 'easy', 'normal', 'hard'],
              onChanged: (v) =>
                  setState(() => _props.difficulty = v!),
            ),
            _divider(),
            // Gamemode
            _dropdownTile(
              title: 'Default gamemode',
              icon: Icons.gamepad,
              value: _props.gamemode,
              items: const [
                'survival',
                'creative',
                'adventure',
                'spectator'
              ],
              onChanged: (v) =>
                  setState(() => _props.gamemode = v!),
            ),
            _divider(),
            // Max players
            _textFieldTile(
              title: 'Max players',
              icon: Icons.people,
              controller: _maxPlayersController,
              keyboardType: TextInputType.number,
            ),
            _divider(),
            // Spawn animals
            _switchTile(
              title: 'Spawn animals',
              subtitle: 'Passive mobs',
              value: _props.spawnAnimals,
              onChanged: (v) =>
                  setState(() => _props.spawnAnimals = v),
              icon: Icons.pets,
              iconColor: Colors.green,
            ),
            _divider(),
            // Spawn monsters
            _switchTile(
              title: 'Spawn monsters',
              subtitle: 'Hostile mobs',
              value: _props.spawnMonsters,
              onChanged: (v) =>
                  setState(() => _props.spawnMonsters = v),
              icon: Icons.bug_report,
              iconColor: Colors.red,
            ),
            _divider(),
            // Spawn NPCs
            _switchTile(
              title: 'Spawn NPCs',
              subtitle: 'Villagers',
              value: _props.spawnNpcs,
              onChanged: (v) =>
                  setState(() => _props.spawnNpcs = v),
              icon: Icons.person,
              iconColor: Colors.blue,
            ),
            _divider(),
            // Mob griefing
            _switchTile(
              title: 'Mob griefing',
              subtitle: 'Mobs can break/change blocks',
              value: _props.mobGriefing,
              onChanged: (v) =>
                  setState(() => _props.mobGriefing = v),
              icon: Icons.broken_image,
              iconColor: Colors.orange,
            ),
            _divider(),
            // Rain
            _switchTile(
              title: 'Weather cycle',
              subtitle: 'Rain and thunderstorms',
              value: _props.rain,
              onChanged: (v) => setState(() => _props.rain = v),
              icon: Icons.water_drop,
              iconColor: Colors.blue,
            ),
          ]),

          const SizedBox(height: 16),

          // ── World ─────────────────────────────────────────
          _sectionHeader('World'),
          _card(children: [
            // World type
            _dropdownTile(
              title: 'World type',
              icon: Icons.public,
              value: _props.worldType,
              items: const [
                'minecraft:normal',
                'minecraft:flat',
                'minecraft:large_biomes',
                'minecraft:amplified',
              ],
              displayNames: const {
                'minecraft:normal': 'Normal',
                'minecraft:flat': 'Flat',
                'minecraft:large_biomes': 'Large biomes',
                'minecraft:amplified': 'Amplified',
              },
              onChanged: (v) =>
                  setState(() => _props.worldType = v!),
            ),
            _divider(),
            // Seed
            _textFieldTile(
              title: 'World seed',
              icon: Icons.agriculture,
              controller: _seedController,
              hint: 'Leave empty for random',
            ),
            _divider(),
            // View distance
            _sliderTile(
              title: 'View distance',
              icon: Icons.visibility,
              value: _props.viewDistance.toDouble(),
              min: 2,
              max: 32,
              divisions: 30,
              label: '${_props.viewDistance} chunks',
              onChanged: (v) =>
                  setState(() => _props.viewDistance = v.round()),
            ),
            _divider(),
            // Spawn protection
            _sliderTile(
              title: 'Spawn protection',
              icon: Icons.security,
              value: _props.spawnProtection.toDouble(),
              min: 0,
              max: 100,
              divisions: 100,
              label: '${_props.spawnProtection} blocks',
              onChanged: (v) => setState(
                  () => _props.spawnProtection = v.round()),
            ),
          ]),

          const SizedBox(height: 16),

          // ── MOTD ──────────────────────────────────────────
          _sectionHeader('Server info'),
          _card(children: [
            _textFieldTile(
              title: 'MOTD',
              icon: Icons.message,
              controller: _motdController,
              hint: 'Message shown in server list',
            ),
            _divider(),
            _textFieldTile(
              title: 'Server port',
              icon: Icons.router,
              controller: _portController,
              keyboardType: TextInputType.number,
            ),
          ]),

          

          const SizedBox(height: 16),

          // ── Advanced (collapsible) ─────────────────────────
          GestureDetector(
            onTap: () =>
                setState(() => _advancedExpanded = !_advancedExpanded),
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 4, vertical: 8),
              child: Row(
                children: [
                  const Text(
                    'Advanced settings',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: Colors.grey,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    _advancedExpanded
                        ? Icons.expand_less
                        : Icons.expand_more,
                    size: 18,
                    color: Colors.grey,
                  ),
                ],
              ),
            ),
          ),

          if (_advancedExpanded)
            _card(children: [
              // Allow flight
              _switchTile(
                title: 'Allow flight',
                subtitle: 'In survival mode',
                value: _props.allowFlight,
                onChanged: (v) =>
                    setState(() => _props.allowFlight = v),
                icon: Icons.flight,
                iconColor: Colors.blue,
              ),
              _divider(),
              // Command blocks
              _switchTile(
                title: 'Command blocks',
                subtitle: 'Enable command block execution',
                value: _props.enableCommandBlock,
                onChanged: (v) =>
                    setState(() => _props.enableCommandBlock = v),
                icon: Icons.terminal,
                iconColor: Colors.purple,
              ),
              _divider(),
              // Force gamemode
              _switchTile(
                title: 'Force gamemode',
                subtitle: 'Reset player gamemode on join',
                value: _props.forceGamemode,
                onChanged: (v) =>
                    setState(() => _props.forceGamemode = v),
                icon: Icons.lock,
                iconColor: Colors.orange,
              ),
              _divider(),
              // Random tick speed
              _textFieldTile(
                title: 'Random tick speed',
                icon: Icons.speed,
                controller: _tickSpeedController,
                keyboardType: TextInputType.number,
                hint: 'Default: 3',
              ),
              _divider(),
              // Simulation distance
              _sliderTile(
                title: 'Simulation distance',
                icon: Icons.sync,
                value: _props.simulationDistance.toDouble(),
                min: 2,
                max: 32,
                divisions: 30,
                label: '${_props.simulationDistance} chunks',
                onChanged: (v) => setState(
                    () => _props.simulationDistance = v.round()),
              ),
            ]),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────

  Widget _warningBanner(String message, Color color) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message,
                style: TextStyle(fontSize: 12, color: color)),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: Colors.grey,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _card({required List<Widget> children}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(children: children),
    );
  }

  Widget _divider() =>
      const Divider(color: Colors.white10, height: 1);

  Widget _switchTile({
    required String title,
    required bool value,
    required Function(bool) onChanged,
    required IconData icon,
    required Color iconColor,
    String? subtitle,
  }) {
    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      activeThumbColor: const Color(0xFF00C853),
      secondary: Icon(icon, size: 20, color: iconColor),
      title: Text(title, style: const TextStyle(fontSize: 13)),
      subtitle: subtitle != null
          ? Text(subtitle,
              style:
                  const TextStyle(fontSize: 11, color: Colors.grey))
          : null,
    );
  }

  Widget _dropdownTile({
    required String title,
    required IconData icon,
    required String value,
    required List<String> items,
    required Function(String?) onChanged,
    Map<String, String>? displayNames,
  }) {
    return ListTile(
      leading: Icon(icon, size: 20, color: Colors.grey),
      title: Text(title, style: const TextStyle(fontSize: 13)),
      trailing: DropdownButton<String>(
        value: value,
        underline: const SizedBox(),
        dropdownColor: const Color(0xFF1A1A1A),
        style: const TextStyle(fontSize: 13, color: Colors.white),
        items: items
            .map((e) => DropdownMenuItem(
                  value: e,
                  child: Text(displayNames?[e] ?? e),
                ))
            .toList(),
        onChanged: onChanged,
      ),
    );
  }

  Widget _textFieldTile({
    required String title,
    required IconData icon,
    required TextEditingController controller,
    TextInputType? keyboardType,
    String? hint,
  }) {
    return ListTile(
      leading: Icon(icon, size: 20, color: Colors.grey),
      title: Text(title, style: const TextStyle(fontSize: 13)),
      trailing: SizedBox(
        width: 140,
        child: TextField(
          controller: controller,
          keyboardType: keyboardType,
          textAlign: TextAlign.right,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            hintText: hint ?? '',
            hintStyle: const TextStyle(
                fontSize: 12, color: Colors.grey),
            border: InputBorder.none,
            isDense: true,
          ),
        ),
      ),
    );
  }

  Widget _sliderTile({
    required String title,
    required IconData icon,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String label,
    required Function(double) onChanged,
  }) {
    return Column(
      children: [
        ListTile(
          leading: Icon(icon, size: 20, color: Colors.grey),
          title: Text(title,
              style: const TextStyle(fontSize: 13)),
          trailing: Text(label,
              style: const TextStyle(
                  fontSize: 12, color: Color(0xFF00C853))),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: const Color(0xFF00C853),
              inactiveTrackColor:
                  const Color(0xFF00C853).withValues(alpha: 0.2),
              thumbColor: const Color(0xFF00C853),
              overlayColor:
                  const Color(0xFF00C853).withValues(alpha: 0.1),
              trackHeight: 3,
            ),
            child: Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }
}