import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'models/app_state.dart';
import 'screens/dashboard/dashboard_screen.dart';
import 'screens/setup_wizard/first_run_screen.dart';
import 'screens/setup_wizard/android_first_run_screen.dart';
import 'services/setup_service.dart';
import 'services/termux_env_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final appState = AppState();
  await appState.load();

  runApp(
    ChangeNotifierProvider.value(
      value: appState,
      child: const PocketServerApp(),
    ),
  );
}

class PocketServerApp extends StatelessWidget {
  const PocketServerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PocketServer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00C853),
          brightness: Brightness.dark,
        ),
      ),
      home: const _StartupRouter(),
    );
  }
}

class _StartupRouter extends StatefulWidget {
  const _StartupRouter();

  @override
  State<_StartupRouter> createState() =>
      _StartupRouterState();
}

class _StartupRouterState extends State<_StartupRouter> {
  bool _checking = true;
  bool _needsSetup = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    if (Platform.isAndroid) {
      // Fast path: check shared prefs first
      final prefs = await SharedPreferences.getInstance();
      final setupDone =
          prefs.getBool('setup_complete') ?? false;

      if (setupDone) {
        // Still verify files exist in background
        final installed =
            await TermuxEnvService.isInstalled();
        final javaOk =
            await TermuxEnvService.isJavaInstalled();
        if (mounted) {
          setState(() {
            _needsSetup = !installed || !javaOk;
            _checking = false;
          });
          // Update cache if something changed
          if (!installed || !javaOk) {
            await prefs.setBool(
                'setup_complete', false);
          }
        }
      } else {
        if (mounted) {
          setState(() {
            _needsSetup = true;
            _checking = false;
          });
        }
      }
    } else {
      final ready =
          await SetupService.isSetupComplete();
      if (mounted) {
        setState(() {
          _needsSetup = !ready;
          _checking = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(
        backgroundColor: Color(0xFF0D0D0D),
        body: Center(
          child: CircularProgressIndicator(
              color: Color(0xFF00C853)),
        ),
      );
    }

    if (_needsSetup) {
      if (Platform.isAndroid) {
        return AndroidFirstRunScreen(
          onComplete: () =>
              setState(() => _needsSetup = false),
        );
      }
      return FirstRunScreen(
        onComplete: () =>
            setState(() => _needsSetup = false),
      );
    }

    return const DashboardScreen();
  }
}