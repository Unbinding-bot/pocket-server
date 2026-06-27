import 'dart:io';
import 'package:flutter/material.dart';
import '../../services/setup_service.dart';

class FirstRunScreen extends StatefulWidget {
  final VoidCallback onComplete;

  const FirstRunScreen({
    super.key,
    required this.onComplete,
  });

  @override
  State<FirstRunScreen> createState() =>
      _FirstRunScreenState();
}

class _FirstRunScreenState
    extends State<FirstRunScreen> {
  final _setup = SetupService();
  bool _started = false;
  SetupStatus _status = const SetupStatus(
    message: 'Ready to set up',
    progress: 0,
  );

  @override
  void initState() {
    super.initState();
    _setup.status.listen((s) {
      if (mounted) setState(() => _status = s);
      if (s.done && s.success) {
        Future.delayed(
            const Duration(milliseconds: 800),
            widget.onComplete);
      }
    });
  }

  @override
  void dispose() {
    _setup.dispose();
    super.dispose();
  }

  String get _platformDescription {
    if (Platform.isAndroid) {
      return 'PocketServer needs to download Java to run '
          'Minecraft servers on your device. '
          'This is a one-time download (~190MB).';
    }
    return 'PocketServer will extract its built-in tools '
        'and set up the server environment. '
        'This only takes a moment.';
  }

  String get _platformTitle {
    if (Platform.isAndroid) return 'Android Setup';
    if (Platform.isWindows) return 'Windows Setup';
    return 'First Run Setup';
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
            constraints: const BoxConstraints(
                maxWidth: 480),
            child: Padding(
              padding: EdgeInsets.all(isSmall ? 24 : 40),
              child: Column(
                mainAxisAlignment:
                    MainAxisAlignment.center,
                children: [
                  // Logo
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
                  Text(
                    _platformTitle,
                    style: TextStyle(
                      fontSize: isSmall ? 13 : 15,
                      color: Colors.grey,
                    ),
                  ),

                  SizedBox(height: isSmall ? 32 : 48),

                  if (!_started) ...[
                    Text(
                      _platformDescription,
                      style: TextStyle(
                        fontSize: isSmall ? 13 : 14,
                        color: Colors.grey,
                        height: 1.6,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    SizedBox(height: isSmall ? 24 : 32),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () {
                          setState(() => _started = true);
                          _setup.runSetup();
                        },
                        icon: const Icon(
                            Icons.play_arrow,
                            size: 20),
                        label: const Text(
                            'Set up PocketServer'),
                        style: FilledButton.styleFrom(
                          backgroundColor:
                              const Color(0xFF00C853),
                          foregroundColor: Colors.black,
                          padding: EdgeInsets.symmetric(
                            vertical: isSmall ? 14 : 18,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                  ] else if (_status.done &&
                      _status.success) ...[
                    const Icon(
                      Icons.check_circle,
                      size: 56,
                      color: Color(0xFF00C853),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'All set!',
                      style: TextStyle(
                        fontSize: 20,
                        color: Colors.white,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Launching PocketServer...',
                      style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey),
                    ),
                  ] else if (_status.isError) ...[
                    const Icon(
                      Icons.error_outline,
                      size: 56,
                      color: Colors.red,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _status.message,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Colors.red,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () =>
                                setState(
                                    () => _started = false),
                            style:
                                OutlinedButton.styleFrom(
                              foregroundColor: Colors.grey,
                              side: const BorderSide(
                                  color: Colors.grey),
                            ),
                            child: const Text('Cancel'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            onPressed: () {
                              _setup.runSetup();
                            },
                            style: FilledButton.styleFrom(
                              backgroundColor:
                                  const Color(0xFF00C853),
                              foregroundColor:
                                  Colors.black,
                            ),
                            child: const Text('Retry'),
                          ),
                        ),
                      ],
                    ),
                  ] else ...[
                    // Progress
                    Column(
                      children: [
                        Text(
                          _status.message,
                          style: const TextStyle(
                            fontSize: 13,
                            color: Colors.grey,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 20),
                        ClipRRect(
                          borderRadius:
                              BorderRadius.circular(8),
                          child: LinearProgressIndicator(
                            value: _status.progress,
                            backgroundColor:
                                Colors.white10,
                            valueColor:
                                const AlwaysStoppedAnimation(
                              Color(0xFF00C853),
                            ),
                            minHeight: 8,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '${(_status.progress * 100).toStringAsFixed(0)}%',
                          style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFF00C853),
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
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