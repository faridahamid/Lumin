import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'services/setup_state.dart';
import 'screens/home_screen.dart';
import 'screens/onboarding_screen.dart';
import 'theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LuminApp());
}

class LuminApp extends StatefulWidget {
  const LuminApp({super.key});

  @override
  State<LuminApp> createState() => _LuminAppState();
}

class _LuminAppState extends State<LuminApp> with WidgetsBindingObserver {
  static const MethodChannel _wakeChannel = MethodChannel('lumin/wake');
  static const MethodChannel _serviceChannel = MethodChannel('lumin/service');
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  late final Future<bool> _setupCompleteFuture;
  bool _wakeWordInteractionActive = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setupCompleteFuture = _resolveInitialSetupComplete();

    _wakeChannel.setMethodCallHandler((call) async {
      if (call.method == "wakeWordDetected") {
        _openHomeFromWakeWord();
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _consumePendingWakeWordLaunch();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Voice screens own the microphone while the app is open. Wake word is
    // started by setup or after a voice flow finishes.
  }

  Future<void> _startWakeWordServiceIfAllowed() async {
    if (_wakeWordInteractionActive) {
      return;
    }

    final micStatus = await Permission.microphone.status;
    if (!micStatus.isGranted) {
      return;
    }

    try {
      await _serviceChannel.invokeMethod('startWakeWordService');
    } catch (_) {
      // Setup screen still handles the first explicit start and any visible errors.
    }
  }

  Future<bool> _consumePendingWakeWordLaunch() async {
    try {
      final launchedFromWakeWord =
          await _serviceChannel.invokeMethod<bool>('consumeWakeWordLaunch') ??
              false;
      if (launchedFromWakeWord) {
        _openHomeFromWakeWord();
      }
      return launchedFromWakeWord;
    } catch (_) {
      // Older native builds will not have this method.
      return false;
    }
  }

  Future<bool> _resolveInitialSetupComplete() async {
    if (await SetupState.isComplete()) {
      return true;
    }

    final micStatus = await Permission.microphone.status;
    if (micStatus.isGranted) {
      await SetupState.markComplete();
      return true;
    }

    return false;
  }

  void _openHomeFromWakeWord() {
    unawaited(_openHomeFromWakeWordIfSetupComplete());
  }

  Future<void> _openHomeFromWakeWordIfSetupComplete() async {
    if (!await SetupState.isComplete()) {
      return;
    }

    _wakeWordInteractionActive = true;
    _navigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
      (route) => false,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'Lumin',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: FutureBuilder<bool>(
        future: _setupCompleteFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const _StartupScreen();
          }

          return snapshot.data == true
              ? const HomeScreen()
              : const OnboardingScreen();
        },
      ),
    );
  }
}

class _StartupScreen extends StatelessWidget {
  const _StartupScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: CircularProgressIndicator(),
      ),
    );
  }
}
