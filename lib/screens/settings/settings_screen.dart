import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../services/drive_service.dart';
import '../../services/tunnel_service.dart';
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
  final TunnelProviderType currentProvider;
  final void Function(TunnelProviderType) onProviderChanged;
  final String frpServerAddr;
  final int frpServerPort;
  final String frpToken;
  final int frpRemotePort;
  final void Function({
    required String serverAddr,
    required int serverPort,
    required String authToken,
    required int remotePort,
  }) onFrpConfigChanged;
  

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
    required this.currentProvider,
    required this.onProviderChanged,
    required this.frpServerAddr,
    required this.frpServerPort,
    required this.frpToken,
    required this.frpRemotePort,
    required this.onFrpConfigChanged,
  });
  
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  
  
  late TextEditingController _tunnelAddressController;
  late TextEditingController _frpServerController;
  late TextEditingController _frpPortController;
  late TextEditingController _frpTokenController;
  late TextEditingController _frpRemotePortController;

  @override
  void initState() {
    super.initState();
    _tunnelAddressController =
        TextEditingController(text: widget.tunnelAddress);
    _frpServerController =
        TextEditingController(text: widget.frpServerAddr);
    _frpPortController =
        TextEditingController(text: widget.frpServerPort.toString());
    _frpTokenController = TextEditingController(text: widget.frpToken);
    _frpRemotePortController =
        TextEditingController(text: widget.frpRemotePort.toString());
  }

  @override
  void dispose() {
    _tunnelAddressController.dispose();
    _frpServerController.dispose();
    _frpPortController.dispose();
    _frpTokenController.dispose();
    _frpRemotePortController.dispose();
    super.dispose();
  }

  void _saveFrpConfig() {
    final port = int.tryParse(_frpPortController.text.trim()) ?? 7000;
    final remotePort =
        int.tryParse(_frpRemotePortController.text.trim()) ?? 25565;
    widget.onFrpConfigChanged(
      serverAddr: _frpServerController.text.trim(),
      serverPort: port,
      authToken: _frpTokenController.text.trim(),
      remotePort: remotePort,
    );
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Server details saved'),
        duration: Duration(seconds: 2),
      ),
    );
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

  void _showTutorial(BuildContext context, TunnelProviderType type) {
    final data = _tutorialFor(type);
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 620),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
                decoration: const BoxDecoration(
                  color: Color(0xFF111111),
                  borderRadius:
                      BorderRadius.vertical(top: Radius.circular(12)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(type.displayName,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w500)),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => Navigator.pop(ctx),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (int i = 0; i < data.steps.length; i++) ...[
                        _tutorialStep(i + 1, data.steps[i]),
                        if (i != data.steps.length - 1)
                          const SizedBox(height: 14),
                      ],
                      const SizedBox(height: 20),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.orange.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: Colors.orange.withValues(alpha: 0.3)),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.info_outline,
                                size: 16, color: Colors.orange),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                data.limitations,
                                style: const TextStyle(
                                    fontSize: 12, color: Colors.orange),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tutorialStep(int number, ({String title, String body}) step) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            color: Color(0xFF00C853),
            shape: BoxShape.circle,
          ),
          child: Text('$number',
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.black)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(step.title,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 3),
              Text(step.body,
                  style:
                      const TextStyle(fontSize: 12.5, color: Colors.grey, height: 1.4)),
            ],
          ),
        ),
      ],
    );
  }

  ({List<({String title, String body})> steps, String limitations})
      _tutorialFor(TunnelProviderType type) {
    switch (type) {
      case TunnelProviderType.playit:
        return (
          steps: [
            (
              title: 'Select Playit.gg and start the tunnel',
              body:
                  'Pick it above, then hit "Start Tunnel" on the dashboard. The app downloads the real playit program the first time — no separate install needed.'
            ),
            (
              title: 'Approve the one-time claim link',
              body:
                  'A banner appears at the top of the dashboard the first time only, with a link to open in your browser. Approve it there, then come back to the app.'
            ),
            (
              title: 'Done — it reconnects on its own after that',
              body:
                  'Once approved, playit remembers your setup. Future starts just connect automatically and fill in your address for you.'
            ),
          ],
          limitations:
              'Windows and Linux only — playit\'s program doesn\'t run on Android at all, for reasons outside the app\'s control (it\'s built against a system library Android doesn\'t have). No account or VPS needed, and it\'s free, but you\'re relying on playit\'s service staying up and free long-term.'
        );

      case TunnelProviderType.frp:
        return (
          steps: [
            (
              title: 'Get a small always-on server (a VPS)',
              body:
                  'This has to be a separate machine with its own public IP — Oracle Cloud\'s "Always Free" tier is genuinely free forever (needs a card for verification, never charged), or a paid VPS like Hetzner/Vultr/DigitalOcean (~\$3-6/month) sets up in minutes with no card-verification hassle.'
            ),
            (
              title: 'Install frps on that server',
              body:
                  'SSH in, download frp\'s server build from its GitHub releases, and run it with a config setting a port (e.g. 7000) and an auth token you make up. Open that port in the VPS\'s firewall.'
            ),
            (
              title: 'Enter your server\'s details here',
              body:
                  'Select "Your own VPS" above, then fill in the server\'s IP (use the IP, not a domain name), the port you chose, and your token. Save.'
            ),
            (
              title: 'Start the tunnel',
              body:
                  'The app downloads frp\'s client automatically and connects using what you entered. Your address is exactly your VPS\'s IP plus the port you chose for players.'
            ),
          ],
          limitations:
              'You\'re responsible for keeping that VPS alive — if it goes down, the tunnel goes down for every platform using it. No bandwidth cap and no third party involved, unlike the other options, and it\'s the only method here that works identically on Windows, Linux, and Android.'
        );

      case TunnelProviderType.portForward:
        return (
          steps: [
            (
              title: 'Check whether you\'re behind CGNAT first',
              body:
                  'Compare your router\'s WAN IP (in its admin page) against what an external "what\'s my IP" site shows. If they don\'t match, or your router\'s WAN IP starts with 100.64–100.127, your ISP has you behind CGNAT and this method can\'t work — skip to another method.'
            ),
            (
              title: 'Forward the port in your router',
              body:
                  'Log into your router\'s admin page, find "Port Forwarding," and forward your Minecraft port (25565 by default) to this device\'s local IP — select this method above and start the tunnel to see that local IP.'
            ),
            (
              title: 'Start the tunnel here',
              body:
                  'The app detects your public IP and shows the address to give players. It can\'t verify the forward actually worked from inside your own network, so the real test is a friend trying to connect.'
            ),
            (
              title: '(Optional) Add dynamic DNS',
              body:
                  'Home IPs can change occasionally. A free service like DuckDNS gives you a fixed name that always points at your current IP, so you\'re not re-sharing a new address after every change.'
            ),
          ],
          limitations:
              'The only method here that\'s completely free with zero ongoing setup on Android — but only if your network actually has a real public IP. Most home WiFi qualifies; mobile data almost never does, since carriers use CGNAT. If your check in step 1 shows CGNAT, this genuinely cannot work no matter how it\'s configured, on any platform.'
        );
    }
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

          // ── Tunnel method picker ────────────────────────────
          _sectionHeader('Tunnel Method'),
          _settingsCard(
            children: [
              for (final type in TunnelProviderType.values) ...[
                if (type != TunnelProviderType.values.first)
                  const Divider(color: Colors.white10, height: 1),
                _providerTile(type),
              ],
            ],
          ),

          const SizedBox(height: 24),

          if (widget.currentProvider == TunnelProviderType.playit)
            _playitSection(context),
          if (widget.currentProvider == TunnelProviderType.frp)
            _frpSection(context),
          if (widget.currentProvider == TunnelProviderType.portForward)
            _portForwardSection(context),

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

  Widget _providerTile(TunnelProviderType type) {
    final selected = widget.currentProvider == type;
    final available = type.availableOnThisPlatform;
    return ListTile(
      leading: Radio<TunnelProviderType>(
        value: type,
        groupValue: widget.currentProvider,
        onChanged: available
            ? (v) {
                if (v != null) widget.onProviderChanged(v);
              }
            : null,
      ),
      title: Text(
        type.displayName,
        style: TextStyle(
          fontSize: 14,
          color: available ? Colors.white : Colors.grey,
        ),
      ),
      subtitle: Text(
        available
            ? type.shortDescription
            : '${type.shortDescription} Not available on this device.',
        style: TextStyle(
          fontSize: 11,
          color: available ? Colors.grey : Colors.red[300],
        ),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.help_outline, size: 20, color: Colors.grey),
        tooltip: 'How to set this up',
        onPressed: () => _showTutorial(context, type),
      ),
      onTap: available ? () => widget.onProviderChanged(type) : null,
    );
  }

  // ── Playit section ───────────────────────────────────────
  Widget _playitSection(BuildContext context) {
    return _settingsCard(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Your tunnel address',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
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
              const Text(
                'Auto-filled once connected. Only edit this manually if detection ever gets it wrong.',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
        ),
        const Divider(color: Colors.white10, height: 1),
        ListTile(
          leading: const Icon(Icons.open_in_browser, color: Colors.blue),
          title:
              const Text('Claim / set up agent', style: TextStyle(fontSize: 13)),
          subtitle: Text(
            widget.claimUrl != null
                ? 'Tap to open claim link'
                : 'Start the tunnel first to get a claim link',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          trailing:
              const Icon(Icons.chevron_right, size: 18, color: Colors.grey),
          onTap: widget.claimUrl == null
              ? null
              : () async {
                  await launchUrl(Uri.parse(widget.claimUrl!),
                      mode: LaunchMode.externalApplication);
                },
        ),
        const Divider(color: Colors.white10, height: 1),
        ListTile(
          leading: const Icon(Icons.restart_alt, color: Colors.orange),
          title: const Text('Reset agent', style: TextStyle(fontSize: 13)),
          subtitle: const Text('Clears saved secret key',
              style: TextStyle(fontSize: 11, color: Colors.grey)),
          trailing:
              const Icon(Icons.chevron_right, size: 18, color: Colors.grey),
          onTap: () => _confirmResetAgent(context),
        ),
        const Divider(color: Colors.white10, height: 1),
        ListTile(
          leading: const Icon(Icons.terminal, color: Color(0xFF00C853)),
          title: const Text('View tunnel logs', style: TextStyle(fontSize: 13)),
          subtitle: Text(widget.tunnelStatus,
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
          trailing:
              const Icon(Icons.chevron_right, size: 18, color: Colors.grey),
          onTap: () => _showTunnelLogs(context),
        ),
      ],
    );
  }

  // ── frp / VPS section ────────────────────────────────────
  Widget _frpSection(BuildContext context) {
    return _settingsCard(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _labeledField('Server address (IP, not a hostname)',
                  _frpServerController, 'e.g. 203.0.113.10'),
              const SizedBox(height: 12),
              _labeledField('Server port', _frpPortController, '7000'),
              const SizedBox(height: 12),
              _labeledField(
                  'Auth token', _frpTokenController, 'from your frps.toml'),
              const SizedBox(height: 12),
              _labeledField('Public port for players', _frpRemotePortController,
                  '25565'),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: _saveFrpConfig,
              child: const Text('Save server details'),
            ),
          ),
        ),
        const Divider(color: Colors.white10, height: 1),
        ListTile(
          leading: const Icon(Icons.terminal, color: Color(0xFF00C853)),
          title: const Text('View tunnel logs', style: TextStyle(fontSize: 13)),
          subtitle: Text(widget.tunnelStatus,
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
          trailing:
              const Icon(Icons.chevron_right, size: 18, color: Colors.grey),
          onTap: () => _showTunnelLogs(context),
        ),
      ],
    );
  }

  Widget _labeledField(
      String label, TextEditingController controller, String hint) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: hint,
            filled: true,
            fillColor: const Color(0xFF0D0D0D),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ],
    );
  }

  // ── Port forwarding section ──────────────────────────────
  Widget _portForwardSection(BuildContext context) {
    return _settingsCard(
      children: [
        ListTile(
          leading: const Icon(Icons.router, color: Color(0xFF00C853)),
          title: Text(
            widget.tunnelAddress.isNotEmpty
                ? widget.tunnelAddress
                : 'Not detected yet',
            style: const TextStyle(fontSize: 14, fontFamily: 'monospace'),
          ),
          subtitle: const Text(
            'Detected address — start the tunnel to check it',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ),
        const Divider(color: Colors.white10, height: 1),
        ListTile(
          leading: const Icon(Icons.terminal, color: Color(0xFF00C853)),
          title: const Text('View details', style: TextStyle(fontSize: 13)),
          subtitle: Text(widget.tunnelStatus,
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
          trailing:
              const Icon(Icons.chevron_right, size: 18, color: Colors.grey),
          onTap: () => _showTunnelLogs(context),
        ),
      ],
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