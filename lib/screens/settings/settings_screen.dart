import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../services/drive_service.dart';
import '../../screens/dashboard/dashboard_screen.dart';


class SettingsScreen extends StatefulWidget {
  final DriveService driveService;
  final bool driveSignedIn;
  final String? driveEmail;
  final VoidCallback onDriveSignOut;
  final VoidCallback onDriveSignIn;
  final Future<String> Function() onResetAgent;
  final String tunnelAddress;
  final Function(String) onTunnelAddressChanged;
  final String tunnelStatus;
  final List<String> tunnelLogs;
  final String? claimUrl;
  

  const SettingsScreen({
    super.key,
    this.claimUrl,
    required this.driveService,
    required this.driveSignedIn,
    required this.driveEmail,
    required this.onDriveSignOut,
    required this.onDriveSignIn,
    required this.onResetAgent,
    required this.tunnelAddress,
    required this.onTunnelAddressChanged,
    required this.tunnelStatus,
    required this.tunnelLogs,
  });
  
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  
  
  late TextEditingController _tunnelAddressController;

  @override
  void initState() {
    super.initState();
    _tunnelAddressController =
        TextEditingController(text: widget.tunnelAddress);
  }

  @override
  void dispose() {
    _tunnelAddressController.dispose();
    super.dispose();
  }

  void _confirmResetAgent(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Reset Playit agent?'),
        content: const Text(
          'This clears the saved secret key. You will need to claim a new agent at playit.gg.',
          style: TextStyle(fontSize: 13, color: Colors.grey),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel',
                style: TextStyle(color: Colors.grey)),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final message = await widget.onResetAgent();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(message),
                    duration: const Duration(seconds: 3),
                  ),
                );
              }
            },
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
  }

  void _showTunnelLogs(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: SizedBox(
          width: 560,
          height: 400,
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                decoration: const BoxDecoration(
                  color: Color(0xFF111111),
                  borderRadius:
                      BorderRadius.vertical(top: Radius.circular(12)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Tunnel logs',
                        style: TextStyle(fontSize: 15,
                            fontWeight: FontWeight.w500)),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => Navigator.pop(ctx),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Container(
                  color: const Color(0xFF0D0D0D),
                  padding: const EdgeInsets.all(12),
                  child: ListView.builder(
                    itemCount: widget.tunnelLogs.length,
                    itemBuilder: (_, i) => Text(
                      widget.tunnelLogs[i],
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: Color(0xFF00C853),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Google Drive ──────────────────────────────────
          _sectionHeader('Google Drive'),
          _settingsCard(
            children: [
              ListTile(
                leading:
                    const Icon(Icons.account_circle, color: Colors.blue),
                title: Text(
                  widget.driveSignedIn
                      ? widget.driveEmail ?? 'Signed in'
                      : 'Not signed in',
                  style: const TextStyle(fontSize: 14),
                ),
                subtitle: Text(
                  widget.driveSignedIn
                      ? 'Tap to sign out'
                      : 'Tap to connect Google Drive',
                  style: const TextStyle(
                      fontSize: 12, color: Colors.grey),
                ),
                trailing: Icon(
                  widget.driveSignedIn ? Icons.logout : Icons.login,
                  color: widget.driveSignedIn ? Colors.red : Colors.blue,
                  size: 20,
                ),
                onTap: widget.driveSignedIn
                    ? widget.onDriveSignOut
                    : widget.onDriveSignIn,
              ),
            ],
          ),

          const SizedBox(height: 24),

          // ── Playit.gg ─────────────────────────────────────
          _sectionHeader('Playit.gg Tunnel'),
          _settingsCard(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Your tunnel address',
                        style:
                            TextStyle(fontSize: 12, color: Colors.grey)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _tunnelAddressController,
                      decoration: InputDecoration(
                        hintText: 'something.joinmc.link',
                        filled: true,
                        fillColor: const Color(0xFF0D0D0D),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none,
                        ),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.save, size: 18),
                          onPressed: () {
                            widget.onTunnelAddressChanged(
                                _tunnelAddressController.text.trim());
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Address saved'),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text('Find this at playit.gg → Tunnels',
                        style:
                            TextStyle(fontSize: 11, color: Colors.grey)),
                  ],
                ),
              ),
              const Divider(color: Colors.white10, height: 1),
              ListTile(
                leading: const Icon(
                    Icons.open_in_browser,
                    color: Colors.blue),
                title: const Text(
                    'Claim / set up agent',
                    style: TextStyle(fontSize: 13)),
                subtitle: Text(
                  widget.claimUrl != null
                      ? 'Tap to open claim link'
                      : 'Start tunnel first to get claim link',
                  style: const TextStyle(
                      fontSize: 11,
                      color: Colors.grey),
                ),
                trailing: const Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: Colors.grey),
                onTap: () async {
                  final url = widget.claimUrl ??
                      'https://playit.gg/claim';
                  await launchUrl(Uri.parse(url),
                      mode: LaunchMode
                          .externalApplication);
                },
              ),
              const Divider(color: Colors.white10, height: 1),
              ListTile(
                leading:
                    const Icon(Icons.restart_alt, color: Colors.orange),
                title: const Text('Reset agent',
                    style: TextStyle(fontSize: 13)),
                subtitle: const Text('Clears saved secret key',
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
                trailing: const Icon(Icons.chevron_right,
                    size: 18, color: Colors.grey),
                onTap: () => _confirmResetAgent(context),
              ),
              const Divider(color: Colors.white10, height: 1),
              ListTile(
                leading: const Icon(Icons.terminal,
                    color: Color(0xFF00C853)),
                title: const Text('View tunnel logs',
                    style: TextStyle(fontSize: 13)),
                subtitle: Text(
                  widget.tunnelStatus,
                  style: const TextStyle(
                      fontSize: 11, color: Colors.grey),
                ),
                trailing: const Icon(Icons.chevron_right,
                    size: 18, color: Colors.grey),
                onTap: () => _showTunnelLogs(context),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // ── About ─────────────────────────────────────────
          _sectionHeader('About'),
          _settingsCard(
            children: [
              const ListTile(
                leading: Icon(Icons.dns, color: Color(0xFF00C853)),
                title: Text('PocketServer',
                    style: TextStyle(fontSize: 14)),
                subtitle: Text('Java Edition',
                    style: TextStyle(
                        fontSize: 12, color: Colors.grey)),
                trailing: Text('v0.1.0',
                    style: TextStyle(
                        fontSize: 12, color: Colors.grey)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: Colors.grey,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _settingsCard({required List<Widget> children}) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(children: children),
    );
  }
}