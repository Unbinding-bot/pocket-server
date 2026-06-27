import 'dart:io';
import 'dart:async';
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:file_picker/file_picker.dart';
import '../../models/server_model.dart';
import '../../widgets/ram_slider.dart';
import '../../services/java_downloader.dart';
import '../../services/platform_service.dart';

class SetupWizard extends StatefulWidget {
  final ServerModel? existingServer;
  final Function(ServerModel) onComplete;

  const SetupWizard({
    super.key,
    this.existingServer,
    required this.onComplete,
  });

  static Future<void> show(
    BuildContext context, {
    ServerModel? existingServer,
    required Function(ServerModel) onComplete,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => SetupWizard(
        existingServer: existingServer,
        onComplete: onComplete,
      ),
    );
  }

  @override
  State<SetupWizard> createState() => _SetupWizardState();
}

class _SetupWizardState extends State<SetupWizard> {

  StreamSubscription? _downloadSub;

  String? _importSourcePath;
  bool _importIsFolder = false;

  final _nameController = TextEditingController();
  final _pathController = TextEditingController();
  final _urlController = TextEditingController();
  ServerType _serverType = ServerType.vanilla;
  String _version = '1.20.4';
  int _ramMb = 1024;
  final List<File> _mods = [];

  final JavaDownloader _downloader = JavaDownloader();
  bool _downloading = false;
  String _downloadStatus = '';
  double _downloadProgress = 0;

  Future<List<String>> _getVersions() => JavaDownloader.versionsForType(_serverType);
  Future<List<String>>? _versionsFuture;
  bool get _isEditing => widget.existingServer != null;
  bool get _isPlugins =>
      _serverType == ServerType.paper;
  String get _modLabel =>
      _isPlugins ? 'Plugins' : 'Mods';

  @override
  void initState() {
    super.initState();
    if (widget.existingServer != null) {
      final s = widget.existingServer!;
      _nameController.text = s.name;
      _pathController.text = s.path;
      _serverType = s.serverType;
      _version = s.version;
      _ramMb = s.ramMb;
      
    } else {
      _setDefaultPath();
    }
    _versionsFuture = JavaDownloader.versionsForType(
        _serverType);
  }

  Future<void> _setDefaultPath() async {
    final serversPath =
        await PlatformService.getServersPath();
    if (mounted) {
      setState(() =>
          _pathController.text = serversPath);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _pathController.dispose();
    _urlController.dispose();
    _downloader.dispose();
    _downloadSub?.cancel();
    super.dispose();
  }

  void _finish() {
    final serverName = _nameController.text.trim().isEmpty
        ? 'my-server'
        : _nameController.text
            .trim()
            .toLowerCase()
            .replaceAll(RegExp(r'[^a-z0-9]'), '-')
            .replaceAll(RegExp(r'-+'), '-');

    final sep = Platform.isWindows ? '\\' : '/';
    final basePath = _pathController.text
        .trim()
        .replaceAll(RegExp(r'[\\/]+$'), '');
    final serverPath = '$basePath$sep$serverName';

    final server = ServerModel(
      id: widget.existingServer?.id ?? const Uuid().v4(),
      name: _nameController.text.trim().isEmpty
          ? 'My Server'
          : _nameController.text.trim(),
      path: serverPath,
      ramMb: _ramMb,
      version: _version,
      serverType: _serverType,
      lastPlayed: widget.existingServer?.lastPlayed,
      mods: _mods.map((f) => f.path).toList(),
    );

    if (widget.existingServer != null &&
        widget.existingServer!.version == _version &&
        widget.existingServer!.serverType == _serverType &&
        _importSourcePath == null) {
      widget.onComplete(server);
      if (mounted) Navigator.pop(context);
      return;
    }

    // Kick off async work separately
    _startDownload(server, serverPath);
  }

  Future<void> _startDownload(
      ServerModel server, String serverPath) async {
    if (_importSourcePath != null) {
      await _handleLocalImport(server, serverPath);
      return;
    }

    setState(() => _downloading = true);

    await _downloadSub?.cancel();
    _downloadSub =
        _downloader.progress.listen((prog) {
      if (!mounted) return;
      setState(() {
        _downloadStatus = prog.status;
        _downloadProgress = prog.progress;
      });
      if (prog.done) {
        _downloadSub?.cancel();
        _downloadSub = null;
        if (prog.success) {
          widget.onComplete(server);
          if (mounted) Navigator.pop(context);
        } else {
          if (mounted) {
            setState(() => _downloading = false);
          }
        }
      }
    });

    _downloader.downloadServerJar(
      version: _version,
      serverPath: serverPath,
      type: _serverType,
    );
  }

  Future<void> _handleLocalImport(
      ServerModel server, String serverPath) async {
    setState(() {
      _downloadStatus = 'Importing server files...';
      _downloadProgress = 0.1;
    });

    try {
      if (_importIsFolder) {
        // Copy folder contents
        setState(() {
          _downloadStatus = 'Copying server folder...';
          _downloadProgress = 0.3;
        });

        await PlatformService.runCommand(
            'mkdir -p "$serverPath"');

        if (Platform.isWindows) {
          // Use xcopy on Windows
          await Process.run(
            'xcopy',
            [
              _importSourcePath!,
              serverPath,
              '/E', '/I', '/H', '/Y',
            ],
            runInShell: true,
          );
        } else {
          await PlatformService.runCommand(
              'cp -r "$_importSourcePath/." "$serverPath/"');
        }
      } else {
        // Extract zip
        setState(() {
          _downloadStatus = 'Extracting backup zip...';
          _downloadProgress = 0.3;
        });

        await PlatformService.runCommand(
            'mkdir -p "$serverPath"');

        // Use Dart archive to extract
        final bytes =
            await File(_importSourcePath!).readAsBytes();
        final archive =
            ZipDecoder().decodeBytes(bytes);

        for (final file in archive) {
          final filePath =
              '$serverPath${Platform.isWindows ? '\\' : '/'}${file.name}';
          if (file.isFile) {
            await File(filePath)
                .create(recursive: true);
            await File(filePath).writeAsBytes(
                file.content as List<int>);
          } else {
            await Directory(filePath)
                .create(recursive: true);
          }
          setState(() => _downloadProgress =
              0.3 + (archive.files.indexOf(file) /
                      archive.files.length) *
                  0.5);
        }
      }

      // Ensure eula.txt
      setState(() {
        _downloadStatus = 'Finalising...';
        _downloadProgress = 0.9;
      });
      await PlatformService.runCommand(
          'echo "eula=true" > "$serverPath/eula.txt"');

      setState(() {
        _downloadStatus = 'Import complete!';
        _downloadProgress = 1.0;
      });

      await Future.delayed(
          const Duration(milliseconds: 500));
      widget.onComplete(server);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() {
        _downloading = false;
        _downloadStatus = 'Import failed: $e';
      });
    }
  }

  Future<void> _pickMods() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jar'],
      allowMultiple: true,
    );
    if (result != null) {
      setState(() {
        for (final file in result.files) {
          if (file.path != null) {
            _mods.add(File(file.path!));
          }
        }
      });
    }
  }

  Future<void> _addFromUrl() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    final fileName =
        url.split('/').last.split('?').first;
    if (!fileName.endsWith('.jar')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('URL must point to a .jar file')),
      );
      return;
    }
    // Store URL as a pending download path
    setState(() {
      _mods.add(File('__url__:$url'));
      _urlController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 560,
        height: MediaQuery.of(context).size.height * 0.85,
        child: Column(
          children: [
            // ── Header ──────────────────────────────────
            Container(
              padding:
                  const EdgeInsets.fromLTRB(24, 20, 24, 16),
              decoration: const BoxDecoration(
                color: Color(0xFF111111),
                borderRadius: BorderRadius.vertical(
                    top: Radius.circular(16)),
              ),
              child: Row(
                mainAxisAlignment:
                    MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _isEditing
                        ? 'Edit Server'
                        : 'New Server',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close,
                        size: 18, color: Colors.grey),
                    onPressed: () =>
                        Navigator.pop(context),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),

            // ── Scrollable content ───────────────────────
            Expanded(
              child: _downloading
                  ? _buildDownloadView()
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          // Server name
                          _sectionHeader('Server name'),
                          TextField(
                            controller: _nameController,
                            autofocus: true,
                            decoration: _inputDecoration(
                              hint: 'My Survival Server',
                              icon: Icons.dns,
                            ),
                          ),

                          const SizedBox(height: 24),

                          // Server type
                          _sectionHeader('Server type'),
                          ...ServerType.values
                              .map((type) => _typeCard(type)),

                          const SizedBox(height: 24),

                          // Version
                          _sectionHeader(
                              '${_serverType.displayName} version'),
                          _versionPicker(),

                          const SizedBox(height: 24),

                          // Path
                          _sectionHeader('Server folder (base directory)'),
                          TextField(
                            controller: _pathController,
                            decoration: _inputDecoration(
                              hint: Platform.isWindows  
                                  ? r'C:\Users\Admin\Documents\PocketServer\servers'
                                  : '/home/user/servers',
                              icon: Icons.folder,
                            ),
                          ),
                          const SizedBox(height: 6),
                          _infoBox(
                            'A folder named after your server will be created here automatically.',
                            Colors.blue,
                          ),
                          const SizedBox(height: 24),
                          _sectionHeader('Import existing server (optional)'),
                          _importSection(),
                          if (_serverType ==
                              ServerType.forge) ...[
                            const SizedBox(height: 6),
                            _infoBox(
                              'Forge installation takes longer. Make sure Java is installed in WSL2.',
                              Colors.orange,
                            ),
                          ],

                          const SizedBox(height: 24),

                          // RAM
                          _sectionHeader(
                              'RAM allocation'),
                          RamSlider(
                            initialRamMb: _ramMb,
                            onChanged: (val) =>
                                setState(() => _ramMb = val),
                          ),
                          const SizedBox(height: 6),
                          _infoBox(
                            _serverType == ServerType.forge
                                ? 'Forge recommended: 3GB+ for modded servers.'
                                : _serverType ==
                                        ServerType.fabric
                                    ? 'Fabric recommended: 2GB+ for modded servers.'
                                    : 'Recommended: 1GB minimum, 2GB+ for plugins.',
                            Colors.orange,
                          ),

                          if (_serverType !=
                              ServerType.vanilla) ...[
                            const SizedBox(height: 24),

                            // Mods / Plugins
                            _sectionHeader(_modLabel),
                            _modsSection(),
                          ],

                          const SizedBox(height: 8),
                        ],
                      ),
                    ),
            ),

            // ── Footer ───────────────────────────────────
            if (!_downloading)
              Container(
                padding: const EdgeInsets.fromLTRB(
                    24, 12, 24, 20),
                decoration: const BoxDecoration(
                  color: Color(0xFF111111),
                  borderRadius: BorderRadius.vertical(
                      bottom: Radius.circular(16)),
                ),
                child: Row(
                  mainAxisAlignment:
                      MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton(
                      onPressed: () =>
                          Navigator.pop(context),
                      child: const Text('Cancel',
                          style: TextStyle(
                              color: Colors.grey)),
                    ),
                    FilledButton.icon(
                      onPressed: _finish,
                      icon: Icon(
                        _isEditing
                            ? Icons.save
                            : Icons.rocket_launch,
                        size: 18,
                      ),
                      label: Text(_isEditing
                          ? 'Save changes'
                          : 'Create server'),
                      style: FilledButton.styleFrom(
                        backgroundColor:
                            const Color(0xFF00C853),
                        foregroundColor: Colors.black,
                        padding:
                            const EdgeInsets.symmetric(
                                horizontal: 24,
                                vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ── Download progress view ─────────────────────────
  Widget _buildDownloadView() {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.downloading,
              size: 48, color: Color(0xFF00C853)),
          const SizedBox(height: 24),
          Text(
            _downloadStatus,
            style: const TextStyle(
                fontSize: 14, color: Colors.grey),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: _downloadProgress,
              backgroundColor: Colors.white10,
              valueColor: const AlwaysStoppedAnimation(
                  Color(0xFF00C853)),
              minHeight: 8,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '${(_downloadProgress * 100).toStringAsFixed(0)}%',
            style: const TextStyle(
              fontSize: 13,
              color: Color(0xFF00C853),
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }

  // ── Server type card ───────────────────────────────
  Widget _typeCard(ServerType type) {
    final selected = type == _serverType;
    return GestureDetector(
      onTap: () async {
        final versions =
            await JavaDownloader.versionsForType(type);
        if (mounted) {
          setState(() {
            _serverType = type;
            _versionsFuture =
                Future.value(versions);
            _version = versions.isNotEmpty
                ? versions.first
                : _version;
          });
        }
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(
            horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF00C853)
                  .withValues(alpha: 0.1)
              : const Color(0xFF0D0D0D),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? const Color(0xFF00C853)
                    .withValues(alpha: 0.5)
                : Colors.transparent,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: selected
                    ? const Color(0xFF00C853)
                        .withValues(alpha: 0.2)
                    : Colors.white
                        .withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                type.icon,
                size: 18,
                color: selected
                    ? const Color(0xFF00C853)
                    : Colors.grey,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Text(
                    type.displayName,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: selected
                          ? const Color(0xFF00C853)
                          : Colors.white,
                    ),
                  ),
                  Text(
                    type.description,
                    style: const TextStyle(
                        fontSize: 11,
                        color: Colors.grey),
                  ),
                ],
              ),
            ),
            if (selected)
              const Icon(Icons.check_circle,
                  color: Color(0xFF00C853), size: 18),
          ],
        ),
      ),
    );
  }

  // ── Version picker ─────────────────────────────────
  Widget _versionPicker() {
    return FutureBuilder<List<String>>(
      future: _versionsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState ==
            ConnectionState.waiting) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(20.0),
              child: CircularProgressIndicator(
                  color: Color(0xFF00C853)),
            ),
          );
        }

        final versions = snapshot.data ?? [];

        if (versions.isEmpty) {
          return const Text(
              'No versions found for this server type.',
              style: TextStyle(color: Colors.grey));
        }

        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: versions.map((v) {
            final selected = v == _version;
            return GestureDetector(
              onTap: () =>
                  setState(() => _version = v),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: selected
                      ? const Color(0xFF00C853)
                          .withValues(alpha: 0.15)
                      : const Color(0xFF0D0D0D),
                  borderRadius:
                      BorderRadius.circular(8),
                  border: Border.all(
                    color: selected
                        ? const Color(0xFF00C853)
                            .withValues(alpha: 0.5)
                        : Colors.white
                            .withValues(alpha: 0.08),
                  ),
                ),
                child: Text(
                  v,
                  style: TextStyle(
                    fontSize: 13,
                    color: selected
                        ? const Color(0xFF00C853)
                        : Colors.white,
                    fontWeight: selected
                        ? FontWeight.w500
                        : FontWeight.normal,
                  ),
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }

  // ── Mods section ───────────────────────────────────
  Widget _modsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // URL input
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _urlController,
                decoration: _inputDecoration(
                  hint: 'Paste download URL (.jar)',
                  icon: Icons.link,
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _addFromUrl,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add URL'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF00C853),
                foregroundColor: Colors.black,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _pickMods,
            icon: const Icon(Icons.folder_open,
                size: 16),
            label: Text('Browse for .jar files'),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF00C853),
              side: const BorderSide(
                  color: Color(0xFF00C853)),
              padding: const EdgeInsets.symmetric(
                  vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ),
        if (_mods.isNotEmpty) ...[
          const SizedBox(height: 12),
          ..._mods.asMap().entries.map((e) {
            final i = e.key;
            final file = e.value;
            final name = file.path.startsWith('__url__:')
                ? file.path.replaceFirst('__url__:', '')
                    .split('/')
                    .last
                : file.path.split('/').last;
            final isUrl =
                file.path.startsWith('__url__:');
            return Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF0D0D0D),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: Colors.white10),
              ),
              child: Row(
                children: [
                  Icon(
                    isUrl
                        ? Icons.link
                        : Icons.extension,
                    size: 16,
                    color: const Color(0xFF00C853),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      name,
                      style: const TextStyle(
                          fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (isUrl)
                    const Text(
                      'URL',
                      style: TextStyle(
                          fontSize: 10,
                          color: Colors.grey),
                    ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => setState(
                        () => _mods.removeAt(i)),
                    child: const Icon(Icons.close,
                        size: 14, color: Colors.grey),
                  ),
                ],
              ),
            );
          }),
        ],
      ],
    );
  }

  // ── Helpers ────────────────────────────────────────
  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: Colors.grey,
          letterSpacing: 0.8,
        ),
      ),
    );
  }

  InputDecoration _inputDecoration({
    required String hint,
    required IconData icon,
  }) {
    return InputDecoration(
      hintText: hint,
      filled: true,
      fillColor: const Color(0xFF0D0D0D),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
      prefixIcon: Icon(icon, size: 18),
    );
  }

  Widget _infoBox(String message, Color color) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border:
            Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(
            color == Colors.blue
                ? Icons.info_outline
                : Icons.warning_amber,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style:
                  TextStyle(fontSize: 11, color: color),
            ),
          ),
        ],
      ),
    );
  }
  Widget _importSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Skip downloading — use an existing server folder or backup zip.',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _pickLocalFolder,
                icon: const Icon(Icons.folder_open, size: 16),
                label: const Text('Import folder'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.teal,
                  side: const BorderSide(color: Colors.teal),
                  padding: const EdgeInsets.symmetric(
                      vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _pickLocalZip,
                icon: const Icon(Icons.archive, size: 16),
                label: const Text('Import zip'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.orange,
                  side:
                      const BorderSide(color: Colors.orange),
                  padding: const EdgeInsets.symmetric(
                      vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          ],
        ),
        if (_importSourcePath != null) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.teal.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: Colors.teal.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                Icon(
                  _importIsFolder
                      ? Icons.folder
                      : Icons.archive,
                  size: 14,
                  color: Colors.teal,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _importSourcePath!.split(
                            Platform.isWindows
                                ? '\\'
                                : '/')
                        .last,
                    style: const TextStyle(
                        fontSize: 12, color: Colors.teal),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                GestureDetector(
                  onTap: () => setState(() {
                    _importSourcePath = null;
                    _importIsFolder = false;
                  }),
                  child: const Icon(Icons.close,
                      size: 14, color: Colors.grey),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _pickLocalFolder() async {
    final result =
        await FilePicker.platform.getDirectoryPath();
    if (result != null) {
      setState(() {
        _importSourcePath = result;
        _importIsFolder = true;
      });
    }
  }

  Future<void> _pickLocalZip() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    if (result != null && result.files.first.path != null) {
      setState(() {
        _importSourcePath = result.files.first.path;
        _importIsFolder = false;
      });
    }
  }
}