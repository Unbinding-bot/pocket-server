import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../../models/server_model.dart';
import '../../services/java_downloader.dart';
import '../../services/platform_service.dart';

class PluginManagerScreen extends StatefulWidget {
  final ServerModel server;
  final Function(ServerModel) onSaved;

  const PluginManagerScreen({
    super.key,
    required this.server,
    required this.onSaved,
  });

  @override
  State<PluginManagerScreen> createState() =>
      _PluginManagerScreenState();
}

class _PluginManagerScreenState extends State<PluginManagerScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late List<String> _mods;
  late List<String> _datapacks;

  bool _downloading = false;
  String _downloadStatus = '';

  final _modUrlController = TextEditingController();
  final _datapackUrlController = TextEditingController();

  bool get _isPlugins =>
      widget.server.serverType == ServerType.paper;
  bool get _showModsTab =>
      widget.server.serverType != ServerType.vanilla;
  String get _modLabel => _isPlugins ? 'Plugin' : 'Mod';
  String get _modFolder => _isPlugins ? 'plugins' : 'mods';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: _showModsTab ? 2 : 1,
      vsync: this,
    );
    _mods = List<String>.from(widget.server.mods);
    _datapacks = [];
    _scanMods();
    _scanDatapacks();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _modUrlController.dispose();
    _datapackUrlController.dispose();
    super.dispose();
  }

  // ─── Scanning (now uses Dart Directory API, works everywhere) ─
  Future<void> _scanMods() async {
    if (!_showModsTab) return;
    try {
      final dir = Directory(
          '${widget.server.path}/$_modFolder');
      if (!await dir.exists()) {
        if (mounted) setState(() => _mods = []);
        return;
      }
      final files = await dir
          .list()
          .where((e) => e is File && e.path.endsWith('.jar'))
          .map((e) => e.path)
          .toList();
      if (mounted) setState(() => _mods = files);
    } catch (_) {
      if (mounted) setState(() => _mods = []);
    }
  }

  Future<void> _scanDatapacks() async {
    try {
      final dir = Directory(
          '${widget.server.path}/world/datapacks');
      if (!await dir.exists()) {
        if (mounted) setState(() => _datapacks = []);
        return;
      }
      final files = await dir
          .list()
          .map((e) => e.path.split('/').last)
          .toList();
      if (mounted) setState(() => _datapacks = files);
    } catch (_) {
      if (mounted) setState(() => _datapacks = []);
    }
  }

  // ─── Mods/Plugins ─────────────────────────────────
  Future<void> _addModFromFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jar'],
      allowMultiple: true,
    );
    if (result == null) return;

    for (final file in result.files) {
      if (file.path == null) continue;
      setState(() {
        _downloadStatus = 'Copying ${file.name}...';
        _downloading = true;
      });

      final destDir = Directory(
          '${widget.server.path}/$_modFolder');
      await destDir.create(recursive: true);
      await File(file.path!).copy(
          '${destDir.path}/${file.name}');
    }

    setState(() {
      _downloading = false;
      _downloadStatus = '';
    });
    await _scanMods();
  }

  Future<void> _addModFromUrl() async {
    final url = _modUrlController.text.trim();
    if (url.isEmpty) return;
    final fileName =
        url.split('/').last.split('?').first;
    if (!fileName.endsWith('.jar')) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content:
                  Text('URL must point to a .jar file')),
        );
      }
      return;
    }

    setState(() {
      _downloading = true;
      _downloadStatus = 'Downloading $fileName...';
    });

    final destDir = Directory(
        '${widget.server.path}/$_modFolder');
    await destDir.create(recursive: true);
    final destPath = '${destDir.path}/$fileName';

    final ok = await PlatformService.downloadFile(
      url: url,
      destPath: destPath,
      onStatus: (s) {
        if (mounted) setState(() => _downloadStatus = s);
      },
    );

    setState(() {
      _downloading = false;
      _downloadStatus = '';
    });

    if (mounted) {
      if (ok) {
        _modUrlController.clear();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$fileName downloaded!')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Download failed'),
              backgroundColor: Colors.red),
        );
      }
    }
    await _scanMods();
  }

  Future<void> _deleteMod(String path) async {
    final confirmed = await _confirmDelete(
        path.split('/').last);
    if (!confirmed) return;
    try {
      await File(path).delete();
    } catch (_) {}
    await _scanMods();
  }

  // ─── Datapacks ────────────────────────────────────
  Future<void> _addDatapackFromFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
      allowMultiple: true,
    );
    if (result == null) return;

    for (final file in result.files) {
      if (file.path == null) continue;
      setState(() {
        _downloadStatus = 'Copying ${file.name}...';
        _downloading = true;
      });

      final destDir = Directory(
          '${widget.server.path}/world/datapacks');
      await destDir.create(recursive: true);
      await File(file.path!).copy(
          '${destDir.path}/${file.name}');
    }

    setState(() {
      _downloading = false;
      _downloadStatus = '';
    });
    await _scanDatapacks();
  }

  Future<void> _addDatapackFromUrl() async {
    final url = _datapackUrlController.text.trim();
    if (url.isEmpty) return;
    final fileName =
        url.split('/').last.split('?').first;
    if (!fileName.endsWith('.zip') &&
        !fileName.endsWith('.jar')) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'URL must point to a .zip or .jar file')),
        );
      }
      return;
    }

    setState(() {
      _downloading = true;
      _downloadStatus = 'Downloading $fileName...';
    });

    final destDir = Directory(
        '${widget.server.path}/world/datapacks');
    await destDir.create(recursive: true);
    final destPath = '${destDir.path}/$fileName';

    final ok = await PlatformService.downloadFile(
      url: url,
      destPath: destPath,
      onStatus: (s) {
        if (mounted) setState(() => _downloadStatus = s);
      },
    );

    setState(() {
      _downloading = false;
      _downloadStatus = '';
    });

    if (mounted) {
      if (ok) {
        _datapackUrlController.clear();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('$fileName downloaded!')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Download failed'),
              backgroundColor: Colors.red),
        );
      }
    }
    await _scanDatapacks();
  }

  Future<void> _deleteDatapack(String name) async {
    final confirmed = await _confirmDelete(name);
    if (!confirmed) return;
    try {
      await File(
          '${widget.server.path}/world/datapacks/$name')
          .delete();
    } catch (_) {}
    await _scanDatapacks();
  }

  Future<bool> _confirmDelete(String name) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text('Delete "$name"?'),
        content: Text(
          'This cannot be undone.',
          style: const TextStyle(
              fontSize: 13, color: Colors.grey),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel',
                style: TextStyle(color: Colors.grey)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
                backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _save() {
    final updated =
        widget.server.copyWith(mods: _mods);
    widget.onSaved(updated);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.server.name} — Assets'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save, size: 18),
              label: const Text('Save'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF00C853),
                foregroundColor: Colors.black,
              ),
            ),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF00C853),
          labelColor: const Color(0xFF00C853),
          unselectedLabelColor: Colors.grey,
          tabs: [
            if (_showModsTab)
              Tab(
                icon: const Icon(Icons.extension, size: 18),
                text: '${_modLabel}s',
              ),
            const Tab(
              icon: Icon(Icons.folder_zip, size: 18),
              text: 'Datapacks',
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          if (_showModsTab) _buildModsTab(),
          _buildDatapacksTab(),
        ],
      ),
    );
  }

  // ─── Mods tab ─────────────────────────────────────
  Widget _buildModsTab() {
    return Column(
      children: [
        _addSection(
          urlController: _modUrlController,
          urlHint:
              'Paste ${_modLabel.toLowerCase()} download URL (.jar)',
          onAddUrl: _addModFromUrl,
          onBrowse: _addModFromFile,
          folderPath:
              '${widget.server.path}/$_modFolder/',
          fileCount: _mods.length,
          downloading: _downloading,
          downloadStatus: _downloadStatus,
        ),
        Expanded(
          child: _mods.isEmpty
              ? _emptyState(
                  '${_modLabel}s', Icons.extension_off)
              : _fileList(
                  files: _mods,
                  nameExtractor: (p) => p.split('/').last,
                  onDelete: _deleteMod,
                  icon: Icons.extension,
                ),
        ),
      ],
    );
  }

  // ─── Datapacks tab ────────────────────────────────
  Widget _buildDatapacksTab() {
    return Column(
      children: [
        _addSection(
          urlController: _datapackUrlController,
          urlHint: 'Paste datapack download URL (.zip)',
          onAddUrl: _addDatapackFromUrl,
          onBrowse: _addDatapackFromFile,
          folderPath:
              '${widget.server.path}/world/datapacks/',
          fileCount: _datapacks.length,
          downloading: _downloading,
          downloadStatus: _downloadStatus,
          browseExtensions: ['zip'],
        ),
        Container(
          color: const Color(0xFF111111),
          padding: const EdgeInsets.symmetric(
              horizontal: 16, vertical: 6),
          child: const Row(
            children: [
              Icon(Icons.info_outline,
                  size: 12, color: Colors.grey),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Datapacks are loaded automatically when the server starts.',
                  style: TextStyle(
                      fontSize: 11, color: Colors.grey),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _datapacks.isEmpty
              ? _emptyState('Datapacks', Icons.folder_zip)
              : _fileList(
                  files: _datapacks,
                  nameExtractor: (n) => n,
                  onDelete: _deleteDatapack,
                  icon: Icons.folder_zip,
                ),
        ),
      ],
    );
  }

  // ─── Shared widgets ───────────────────────────────
  Widget _addSection({
    required TextEditingController urlController,
    required String urlHint,
    required VoidCallback onAddUrl,
    required VoidCallback onBrowse,
    required String folderPath,
    required int fileCount,
    required bool downloading,
    required String downloadStatus,
    List<String> browseExtensions = const ['jar'],
  }) {
    return Container(
      color: const Color(0xFF1A1A1A),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: urlController,
                  decoration: InputDecoration(
                    hintText: urlHint,
                    filled: true,
                    fillColor: const Color(0xFF0D0D0D),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                    prefixIcon:
                        const Icon(Icons.link, size: 18),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: downloading ? null : onAddUrl,
                icon: downloading
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.black,
                        ),
                      )
                    : const Icon(Icons.download, size: 16),
                label: const Text('Download'),
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
              onPressed: downloading ? null : onBrowse,
              icon: const Icon(Icons.folder_open, size: 16),
              label: const Text('Browse files'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF00C853),
                side: const BorderSide(
                    color: Color(0xFF00C853)),
                padding:
                    const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
          if (downloading && downloadStatus.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFF00C853),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  downloadStatus,
                  style: const TextStyle(
                      fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.folder,
                  size: 12, color: Colors.grey),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  folderPath,
                  style: const TextStyle(
                    fontSize: 10,
                    color: Colors.grey,
                    fontFamily: 'monospace',
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '$fileCount file${fileCount == 1 ? '' : 's'}',
                style: const TextStyle(
                    fontSize: 10, color: Colors.grey),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _fileList({
    required List<String> files,
    required String Function(String) nameExtractor,
    required Future<void> Function(String) onDelete,
    required IconData icon,
  }) {
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: files.length,
      itemBuilder: (_, i) {
        final file = files[i];
        final name = nameExtractor(file);
        return Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(
              horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(8),
            border:
                Border.all(color: Colors.white10),
          ),
          child: Row(
            children: [
              Icon(icon,
                  size: 16,
                  color: const Color(0xFF00C853)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  name,
                  style: const TextStyle(fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline,
                    size: 18, color: Colors.red),
                onPressed: () => onDelete(file),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _emptyState(String label, IconData icon) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: Colors.grey[800]),
          const SizedBox(height: 12),
          Text(
            'No $label yet',
            style: const TextStyle(
                color: Colors.grey, fontSize: 13),
          ),
        ],
      ),
    );
  }
}