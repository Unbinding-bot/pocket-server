import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/app_state.dart';
import '../../models/server_model.dart';
import '../../services/java_downloader.dart';

class ServerListDrawer extends StatelessWidget {
  final String? activeServerId;
  final Function(ServerModel) onServerSelected;
  final VoidCallback onAddServer;
  final Function(ServerModel) onEditServer;
  final Function(ServerModel, {bool deleteFiles}) onDeleteServer;

  const ServerListDrawer({
    super.key,
    required this.activeServerId,
    required this.onServerSelected,
    required this.onAddServer,
    required this.onEditServer,
    required this.onDeleteServer,
  });


  String _formatLastPlayed(DateTime? dt) {
    if (dt == null) return 'Never played';
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.day}/${dt.month}/${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final servers = appState.servers;

    return Drawer(
      backgroundColor: const Color(0xFF111111),
      child: Column(
        children: [
          // Header
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 48, 16, 16),
            color: const Color(0xFF1A1A1A),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.dns,
                        color: Color(0xFF00C853), size: 24),
                    const SizedBox(width: 10),
                    const Text(
                      'PocketServer',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w500,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${servers.length} server${servers.length == 1 ? '' : 's'}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),

          // Server list
          Expanded(
            child: servers.isEmpty
                ? const Center(
                    child: Text(
                      'No servers yet.\nTap + to create one.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey, fontSize: 13),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: servers.length,
                    itemBuilder: (_, i) {
                      final server = servers[i];
                      final isActive = server.id == activeServerId;
                      final isRunning =
                          appState.runningServerId == server.id;

                      return Container(
                        margin: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: isActive
                              ? const Color(0xFF00C853).withValues(alpha: 0.1)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isActive
                                ? const Color(0xFF00C853).withValues(alpha: 0.3)
                                : Colors.transparent,
                          ),
                        ),
                        child: ListTile(
                          onTap: () {
                            onServerSelected(server);
                            Navigator.pop(context);
                          },
                          leading: Stack(
                            children: [
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF00C853)
                                      .withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Icon(Icons.storage,
                                    color: Color(0xFF00C853), size: 20),
                              ),
                              if (isRunning)
                                Positioned(
                                  right: 0,
                                  bottom: 0,
                                  child: Container(
                                    width: 10,
                                    height: 10,
                                    decoration: BoxDecoration(
                                      color: Colors.green,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: const Color(0xFF111111),
                                        width: 1.5,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          title: Text(
                            server.name,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: isActive
                                  ? const Color(0xFF00C853)
                                  : Colors.white,
                            ),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 2),
                              SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Row(
                                  children: [
                                    _chip(server.version, Icons.tag),
                                    const SizedBox(width: 6),
                                    _chip(server.serverType.displayName,
                                      server.serverType.icon),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                _formatLastPlayed(server.lastPlayed),
                                style: const TextStyle(
                                    fontSize: 11, color: Colors.grey),
                              ),
                            ],
                          ),
                          trailing: SizedBox(
                            width: 80,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                GestureDetector(
                                  onTap: () {
                                    Navigator.pop(context);
                                    onEditServer(server);
                                  },
                                  child: const Icon(Icons.edit,
                                      size: 16,
                                      color: Colors.grey),
                                ),
                                const SizedBox(width: 6),
                                GestureDetector(
                                  onTap: () =>
                                      _confirmDelete(context, server),
                                  child: const Icon(
                                      Icons.delete_outline,
                                      size: 16,
                                      color: Colors.red),
                                ),
                                if (isActive) ...[
                                  const SizedBox(width: 4),
                                  const Icon(
                                      Icons.chevron_right,
                                      color: Color(0xFF00C853),
                                      size: 16),
                                ],
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),

          // Add server button
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onAddServer,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('New Server'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF00C853),
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(BuildContext context, ServerModel server) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text('Delete "${server.name}"?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Keep files
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.folder_off, color: Colors.orange),
              title: const Text('Remove from list',
                  style: TextStyle(fontSize: 13)),
              subtitle: const Text('Keep server files on disk',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.pop(context);
                onDeleteServer(server);
              },
            ),
            const Divider(color: Colors.white10),
            // Delete files too
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading:
                  const Icon(Icons.delete_forever, color: Colors.red),
              title: const Text('Delete everything',
                  style: TextStyle(fontSize: 13, color: Colors.red)),
              subtitle: const Text('Remove list entry AND all files',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.pop(context);
                onDeleteServer(server, deleteFiles: true);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel',
                style: TextStyle(color: Colors.grey)),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: Colors.grey),
          const SizedBox(width: 3),
          Text(label,
              style: const TextStyle(fontSize: 10, color: Colors.grey)),
        ],
      ),
    );
  }
}