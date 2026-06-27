import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../../models/app_state.dart';
import '../../models/server_model.dart';
import '../../services/drive_service.dart';

class DriveBrowserScreen extends StatefulWidget {
  final DriveService driveService;
  final Function(ServerModel) onImported;

  const DriveBrowserScreen({
    super.key,
    required this.driveService,
    required this.onImported,
  });

  @override
  State<DriveBrowserScreen> createState() =>
      _DriveBrowserScreenState();
}

class _DriveBrowserScreenState
    extends State<DriveBrowserScreen> {
  final List<_BreadcrumbItem> _breadcrumbs = [
    _BreadcrumbItem(id: null, name: 'My Drive'),
  ];
  List<DriveItem> _items = [];
  bool _loading = true;
  bool _importing = false;
  String _importStatus = '';

  @override
  void initState() {
    super.initState();
    _loadFolder(null);
  }

  Future<void> _loadFolder(String? folderId) async {
    setState(() => _loading = true);
    final items =
        await widget.driveService.listFolder(folderId);
    if (mounted) {
      setState(() {
        _items = items;
        _loading = false;
      });
    }
  }

  void _navigateInto(DriveItem item) {
    setState(() {
      _breadcrumbs
          .add(_BreadcrumbItem(id: item.id, name: item.name));
    });
    _loadFolder(item.id);
  }

  void _navigateTo(int index) {
    if (index >= _breadcrumbs.length - 1) return;
    setState(() {
      _breadcrumbs.removeRange(
          index + 1, _breadcrumbs.length);
    });
    _loadFolder(_breadcrumbs[index].id);
  }

  Future<void> _selectFile(DriveItem item) async {
    if (!item.name.endsWith('.zip')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Please select a .zip backup file'),
        ),
      );
      return;
    }

    // Ask what to do with the backup
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text('Import "${item.name}"?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Size: ${item.formattedSize}',
              style: const TextStyle(
                  fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            const Text(
              'What would you like to do?',
              style: TextStyle(fontSize: 13),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel',
                style: TextStyle(color: Colors.grey)),
          ),
          OutlinedButton.icon(
            onPressed: () =>
                Navigator.pop(ctx, 'existing'),
            icon: const Icon(Icons.folder_open,
                size: 16),
            label:
                const Text('Extract to existing server'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.orange,
              side:
                  const BorderSide(color: Colors.orange),
            ),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, 'new'),
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Create new server'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF00C853),
              foregroundColor: Colors.black,
            ),
          ),
        ],
      ),
    );

    if (choice == null) return;

    if (choice == 'new') {
      await _importAsNew(item);
    } else {
      await _importToExisting(item);
    }
  }

  Future<void> _importAsNew(DriveItem item) async {
    // Ask for server name and path
    final nameController = TextEditingController(
        text: item.name
            .replaceAll('.zip', '')
            .replaceAll(RegExp(r'_\d{4}-\d{2}-\d{2}.*'), ''));
    final pathController = TextEditingController(
        text: '/home/unbinding/servers/${nameController.text.toLowerCase().replaceAll(' ', '_')}');

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('New server from backup'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Server name',
                style: TextStyle(
                    fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 4),
            TextField(
              controller: nameController,
              decoration: InputDecoration(
                filled: true,
                fillColor: const Color(0xFF0D0D0D),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Text('Install path (WSL2)',
                style: TextStyle(
                    fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 4),
            TextField(
              controller: pathController,
              decoration: InputDecoration(
                filled: true,
                fillColor: const Color(0xFF0D0D0D),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ],
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
              backgroundColor: const Color(0xFF00C853),
              foregroundColor: Colors.black,
            ),
            child: const Text('Import'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    
    await _doImport(
      item: item,
      serverName: nameController.text.trim(),
      serverPath: pathController.text.trim(),
      createNew: true,
    );
  }

  Future<void> _importToExisting(DriveItem item) async {
    final appState = context.read<AppState>();
    final servers = appState.servers;

    if (servers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'No servers found. Create one first.')),
      );
      return;
    }

    ServerModel? selected;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Select server'),
        content: SizedBox(
          width: 300,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: servers.length,
            itemBuilder: (_, i) {
              final server = servers[i];
              return ListTile(
                title: Text(server.name,
                    style:
                        const TextStyle(fontSize: 13)),
                subtitle: Text(server.path,
                    style: const TextStyle(
                        fontSize: 11,
                        color: Colors.grey)),
                onTap: () {
                  selected = server;
                  Navigator.pop(ctx);
                },
              );
            },
          ),
        ),
      ),
    );

    if (selected == null) return;

    await _doImport(
      item: item,
      serverName: selected!.name,
      serverPath: selected!.path,
      createNew: false,
      existingServer: selected,
    );
  }

  Future<void> _doImport({
    required DriveItem item,
    required String serverName,
    required String serverPath,
    required bool createNew,
    ServerModel? existingServer,
  }) async {
    setState(() {
      _importing = true;
      _importStatus = 'Downloading from Google Drive...';
    });

    // Read context-dependent objects before any awaits
    final appState = context.read<AppState>();

    // Download zip to Windows temp
    final tempPath = await widget.driveService.downloadFile(
      fileId: item.id,
      fileName: item.name,
      onStatus: (s) {
        if (mounted) setState(() => _importStatus = s);
      },
    );

    if (tempPath == null) {
      setState(() => _importing = false);
      return;
    }

    setState(
        () => _importStatus = 'Extracting to WSL2...');

    // Create server folder
    await Process.run('wsl.exe',
        ['-e', 'mkdir', '-p', serverPath]);

    // Convert Windows temp path to WSL2 path
    final wslTempPath = tempPath
        .replaceAll('\\', '/')
        .replaceFirstMapped(
            RegExp(r'^([A-Za-z]):'),
            (m) =>
                '/mnt/${m.group(1)!.toLowerCase()}');

    // Extract zip into server folder
    final extract = await Process.run('wsl.exe', [
      '-e', 'bash', '-c',
      'cd "$serverPath" && unzip -o "$wslTempPath" 2>&1',
    ]);

    // Clean up temp file
    await File(tempPath).delete();

    if (extract.exitCode != 0) {
      if (mounted) {
        setState(() => _importing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Extraction failed: ${extract.stderr}'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    setState(
        () => _importStatus = 'Finalising server...');

    // Make sure eula.txt exists
    await Process.run('wsl.exe', [
      '-e', 'bash', '-c',
      'echo "eula=true" > "$serverPath/eula.txt"',
    ]);

    if (createNew) {
      final server = ServerModel(
        id: const Uuid().v4(),
        name: serverName,
        path: serverPath,
        ramMb: 1024,
        version: '1.20.4',
        lastPlayed: DateTime.now(),
      );

      if (mounted) {
        await appState.addServer(server);
        await appState.setActiveServer(server);
        widget.onImported(server);
        Navigator.pop(context);
      }
    } else {
      if (mounted) {
        widget.onImported(existingServer!);
        Navigator.pop(context);
      }
    }

    setState(() => _importing = false);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${item.name} imported successfully!'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Google Drive'),
      ),
      body: _importing
          ? _buildImportProgress()
          : Column(
              children: [
                // Breadcrumbs
                Container(
                  color: const Color(0xFF1A1A1A),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      const Icon(Icons.cloud,
                          size: 16, color: Colors.grey),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection:
                              Axis.horizontal,
                          child: Row(
                            children: _breadcrumbs
                                .asMap()
                                .entries
                                .map((e) {
                              final isLast = e.key ==
                                  _breadcrumbs.length - 1;
                              return Row(
                                mainAxisSize:
                                    MainAxisSize.min,
                                children: [
                                  GestureDetector(
                                    onTap: isLast
                                        ? null
                                        : () => _navigateTo(
                                            e.key),
                                    child: Text(
                                      e.value.name,
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: isLast
                                            ? Colors.white
                                            : Colors.blue,
                                        fontWeight: isLast
                                            ? FontWeight
                                                .w500
                                            : FontWeight
                                                .normal,
                                      ),
                                    ),
                                  ),
                                  if (!isLast)
                                    const Padding(
                                      padding: EdgeInsets
                                          .symmetric(
                                              horizontal:
                                                  6),
                                      child: Icon(
                                          Icons
                                              .chevron_right,
                                          size: 16,
                                          color:
                                              Colors.grey),
                                    ),
                                ],
                              );
                            }).toList(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Info banner
                Container(
                  color: const Color(0xFF111111),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 6),
                  child: const Row(
                    children: [
                      Icon(Icons.info_outline,
                          size: 12, color: Colors.grey),
                      SizedBox(width: 6),
                      Text(
                        'Browse to your backup .zip and tap it to import',
                        style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey),
                      ),
                    ],
                  ),
                ),

                // File list
                Expanded(
                  child: _loading
                      ? const Center(
                          child:
                              CircularProgressIndicator(
                            color: Color(0xFF00C853),
                          ),
                        )
                      : _items.isEmpty
                          ? const Center(
                              child: Text(
                                'This folder is empty',
                                style: TextStyle(
                                    color: Colors.grey),
                              ),
                            )
                          : ListView.builder(
                              padding:
                                  const EdgeInsets.all(
                                      12),
                              itemCount: _items.length,
                              itemBuilder: (_, i) {
                                final item = _items[i];
                                return _buildItem(item);
                              },
                            ),
                ),
              ],
            ),
    );
  }

  Widget _buildItem(DriveItem item) {
    final isZip = item.name.endsWith('.zip');
    final color = item.isFolder
        ? Colors.amber
        : isZip
            ? const Color(0xFF00C853)
            : Colors.grey;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isZip
              ? const Color(0xFF00C853)
                  .withValues(alpha: 0.3)
              : Colors.white10,
        ),
      ),
      child: ListTile(
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(
            item.isFolder
                ? Icons.folder
                : isZip
                    ? Icons.archive
                    : Icons.insert_drive_file,
            color: color,
            size: 18,
          ),
        ),
        title: Text(
          item.name,
          style: TextStyle(
            fontSize: 13,
            color: isZip ? Colors.white : Colors.grey,
            fontWeight: isZip
                ? FontWeight.w500
                : FontWeight.normal,
          ),
        ),
        subtitle: item.isFolder
            ? null
            : Text(
                item.formattedSize,
                style: const TextStyle(
                    fontSize: 11, color: Colors.grey),
              ),
        trailing: item.isFolder
            ? const Icon(Icons.chevron_right,
                color: Colors.grey, size: 18)
            : isZip
                ? const Icon(Icons.download,
                    color: Color(0xFF00C853), size: 18)
                : null,
        onTap: () {
          if (item.isFolder) {
            _navigateInto(item);
          } else if (isZip) {
            _selectFile(item);
          }
        },
      ),
    );
  }

  Widget _buildImportProgress() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(
              color: Color(0xFF00C853),
            ),
            const SizedBox(height: 24),
            Text(
              _importStatus,
              style: const TextStyle(
                  fontSize: 14, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _BreadcrumbItem {
  final String? id;
  final String name;
  _BreadcrumbItem({required this.id, required this.name});
}