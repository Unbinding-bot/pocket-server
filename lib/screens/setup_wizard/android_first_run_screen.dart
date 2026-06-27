import 'package:flutter/material.dart';
import '../../services/termux_env_service.dart';
import '../../services/setup_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AndroidFirstRunScreen extends StatefulWidget {
  final VoidCallback onComplete;

  const AndroidFirstRunScreen({
    super.key,
    required this.onComplete,
  });

  @override
  State<AndroidFirstRunScreen> createState() =>
      _AndroidFirstRunScreenState();
}

class _AndroidFirstRunScreenState
    extends State<AndroidFirstRunScreen> {
  bool _started = false;
  bool _done = false;
  bool _error = false;
  String _status = '';
  double _progress = 0;

  Future<void> _start() async {
    setState(() {
      _started = true;
      _status = 'Starting setup...';
      _progress = 0.05;
    });

    final ok = await TermuxEnvService.setup(
        (msg, prog) {
      if (mounted) {
        setState(() {
          _status = msg;
          _progress = prog;
        });
      }
    });

    if (mounted) {
      if (ok) {
        await SetupService.markSetupComplete();
        // Cache so next launch is instant
        final prefs =
            await SharedPreferences.getInstance();
        await prefs.setBool('setup_complete', true);
        setState(() {
          _done = true;
          _progress = 1.0;
          _status = 'All done!';
        });
        await Future.delayed(
            const Duration(milliseconds: 800));
        widget.onComplete();
      } else {
        setState(() {
          _error = true;
          _status = 'Setup failed — tap retry';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isSmall = size.width < 600;

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints:
                const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding:
                  EdgeInsets.all(isSmall ? 24 : 40),
              child: Column(
                mainAxisAlignment:
                    MainAxisAlignment.center,
                children: [
                  Container(
                    width: isSmall ? 72 : 96,
                    height: isSmall ? 72 : 96,
                    decoration: BoxDecoration(
                      color: const Color(0xFF00C853)
                          .withValues(alpha: 0.1),
                      borderRadius:
                          BorderRadius.circular(24),
                      border: Border.all(
                        color: const Color(0xFF00C853)
                            .withValues(alpha: 0.3),
                      ),
                    ),
                    child: Icon(
                      Icons.dns,
                      size: isSmall ? 36 : 48,
                      color: const Color(0xFF00C853),
                    ),
                  ),
                  SizedBox(height: isSmall ? 20 : 32),
                  Text(
                    'PocketServer',
                    style: TextStyle(
                      fontSize: isSmall ? 24 : 32,
                      fontWeight: FontWeight.w500,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Android Setup',
                    style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey),
                  ),
                  SizedBox(height: isSmall ? 32 : 48),
                  if (!_started) ...[
                    const Text(
                      'PocketServer needs to set up a '
                      'Java environment to run '
                      'Minecraft servers on your device.\n\n'
                      'This is a one-time setup.',
                      style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey,
                          height: 1.6),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 32),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _start,
                        icon: const Icon(
                            Icons.play_arrow,
                            size: 20),
                        label: const Text(
                            'Set up PocketServer'),
                        style: FilledButton.styleFrom(
                          backgroundColor:
                              const Color(0xFF00C853),
                          foregroundColor: Colors.black,
                          padding:
                              EdgeInsets.symmetric(
                            vertical:
                                isSmall ? 14 : 18,
                          ),
                          shape:
                              RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(
                                    10),
                          ),
                        ),
                      ),
                    ),
                  ] else if (_done) ...[
                    const Icon(Icons.check_circle,
                        size: 56,
                        color: Color(0xFF00C853)),
                    const SizedBox(height: 16),
                    const Text('All set!',
                        style: TextStyle(
                            fontSize: 20,
                            color: Colors.white,
                            fontWeight:
                                FontWeight.w500)),
                    const SizedBox(height: 8),
                    const Text(
                        'Launching PocketServer...',
                        style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey)),
                  ] else if (_error) ...[
                    const Icon(Icons.error_outline,
                        size: 56, color: Colors.red),
                    const SizedBox(height: 16),
                    Text(_status,
                        style: const TextStyle(
                            fontSize: 13,
                            color: Colors.red),
                        textAlign: TextAlign.center),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: () {
                        setState(() {
                          _started = false;
                          _error = false;
                        });
                      },
                      style: FilledButton.styleFrom(
                          backgroundColor: Colors.red),
                      child: const Text('Retry'),
                    ),
                  ] else ...[
                    Text(_status,
                        style: const TextStyle(
                            fontSize: 13,
                            color: Colors.grey),
                        textAlign: TextAlign.center),
                    const SizedBox(height: 20),
                    ClipRRect(
                      borderRadius:
                          BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: _progress,
                        backgroundColor: Colors.white10,
                        valueColor:
                            const AlwaysStoppedAnimation(
                                Color(0xFF00C853)),
                        minHeight: 8,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '${(_progress * 100).toStringAsFixed(0)}%',
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF00C853),
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}