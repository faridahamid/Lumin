import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

import 'object_detection_screen.dart';
import 'ocr_screen.dart';
import 'metrics_screen.dart';
import 'profile_screen.dart';
import 'web_search_screen.dart';
import '../services/performance_metrics.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const String _voiceAssistantUrl = String.fromEnvironment(
    'LUMIN_VOICE_ASSISTANT_URL',
    defaultValue: 'http://10.0.2.2:3000/ask',
  );
  static const MethodChannel _serviceChannel = MethodChannel('lumin/service');
  static const MethodChannel _nativeSpeechChannel =
      MethodChannel('lumin/native_speech');

  bool _listening = false;
  bool _navigating = false;
  bool _nativeListening = false;
  String _status = 'Listening for what you need';
  String _heard = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_startVoiceRouter());
    });
  }

  @override
  void dispose() {
    unawaited(_stopNativeSpeech());
    super.dispose();
  }

  Future<void> _startVoiceRouter() async {
    if (_navigating || _listening || _nativeListening) {
      return;
    }

    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      if (mounted) {
        setState(() => _status = 'Microphone permission is required');
      }
      return;
    }

    await _tryNativeVoiceRouter();
  }

  Future<void> _tryNativeVoiceRouter() async {
    if (_nativeListening || _navigating) {
      return;
    }
    _nativeListening = true;
    try {
      await _stopWakeWordService();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (mounted) {
        setState(() {
          _heard = '';
          _listening = true;
          _status = 'Listening for 4 seconds... speak now';
        });
      }

      final raw = await _recordAndTranscribe();
      final words = (raw['transcript'] ?? '').toString().trim();
      final error = (raw['error'] ?? '').toString().trim();

      if (!mounted || _navigating) {
        return;
      }
      if (words.isNotEmpty) {
        setState(() {
          _heard = words;
          _status = 'Opening...';
        });
        final route = await _routeHomeCommand(words);
        final destination = route['destination'];
        final clarification = (route['clarification'] ?? '').toString().trim();
        if (destination == 'object_detection') {
          await _openPage(const ObjectDetectionScreen(autoListen: true));
        } else if (destination == 'ocr') {
          await _openPage(const OCRScreen());
        } else if (destination == 'web_search') {
          await _openPage(const WebSearchScreen());
        } else {
          setState(() {
            _status = clarification.isEmpty
                ? 'Do you want camera, text reading, or web search?'
                : clarification;
          });
          _restartRouterSoon();
        }
        return;
      }

      setState(() {
        _status = error.isEmpty
            ? 'I did not hear clearly. Listening again.'
            : 'Speech error: $error. Listening again.';
      });
      _restartRouterSoon();
    } catch (error) {
      if (mounted && !_navigating) {
        setState(() => _status = 'Native speech failed: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _listening = false);
      }
      _nativeListening = false;
    }
  }

  Future<Map<dynamic, dynamic>> _recordAndTranscribe() async {
    final recording =
        await _nativeSpeechChannel.invokeMethod<Map<dynamic, dynamic>>(
      'recordWav',
      {'durationMillis': 4000},
    );
    final recordError = (recording?['error'] ?? '').toString().trim();
    if (recordError.isNotEmpty) {
      return {'error': recordError};
    }

    final audioBase64 = (recording?['audioBase64'] ?? '').toString();
    final audioMimeType = (recording?['audioMimeType'] ?? 'audio/wav').toString();
    final max = int.tryParse((recording?['max'] ?? '0').toString()) ?? 0;
    if (audioBase64.isEmpty) {
      return {'error': 'empty_recording'};
    }
    if (max < 150) {
      return {'error': 'recorded_audio_too_quiet'};
    }

    final stopwatch = Stopwatch()..start();
    final response = await http
        .post(
          _transcribeUri(),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'audioBase64': audioBase64,
            'audioMimeType': audioMimeType,
            'language': 'ar',
          }),
        )
        .timeout(const Duration(seconds: 45));
    PerformanceMetrics.logDuration('transcription_latency_ms', stopwatch);

    if (response.statusCode >= 400) {
      return {'error': 'transcribe_${response.statusCode}: ${response.body}'};
    }

    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    return {'transcript': (decoded['text'] ?? '').toString()};
  }

  Uri _transcribeUri() {
    final askUri = Uri.parse(_voiceAssistantUrl);
    final path = askUri.path.endsWith('/ask')
        ? askUri.path.substring(0, askUri.path.length - 4)
        : askUri.path;
    return askUri.replace(path: '$path/transcribe');
  }

  Future<Map<String, Object?>> _routeHomeCommand(String command) async {
    Object? lastError;
    for (final url in _routeHomeUrls().toSet()) {
      try {
        final response = await http
            .post(
              Uri.parse(url),
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode({'command': command}),
            )
            .timeout(const Duration(seconds: 45));
        if (response.statusCode >= 200 && response.statusCode < 300) {
          final decoded = jsonDecode(utf8.decode(response.bodyBytes));
          if (decoded is Map<String, dynamic>) {
            return decoded;
          }
        }
        lastError = 'Router $url returned ${response.statusCode}: ' 
            '${response.body}';
      } catch (error) {
        lastError = '$url failed: $error';
      }
    }

    return {
      'tool': 'clarify',
      'clarification': 'Router failed: $lastError',
    };
  }

  List<String> _routeHomeUrls() {
    final urls = <String>[
      _routeHomeUrlFrom(_voiceAssistantUrl),
    ];
    final emulator = _routeHomeUrlFrom('http://127.0.0.1:3000/ask');
    if (!urls.contains(emulator)) {
      urls.add(emulator);
    }
    return urls;
  }

  String _routeHomeUrlFrom(String askUrl) {
    final uri = Uri.parse(askUrl);
    final path = uri.path.endsWith('/ask')
        ? uri.path.substring(0, uri.path.length - 4)
        : uri.path;
    return uri.replace(path: '$path/route-home-command').toString();
  }

  Future<void> _openPage(Widget page) async {
    _navigating = true;
    await _stopNativeSpeech();
    if (!mounted) {
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => page),
    );
    _navigating = false;
    if (mounted) {
      _restartRouterSoon();
    }
  }

  void _restartRouterSoon() {
    Future<void>.delayed(const Duration(milliseconds: 500), () {
      if (mounted && !_navigating) {
        unawaited(_startVoiceRouter());
      }
    });
  }

  Future<void> _stopWakeWordService() async {
    try {
      await _serviceChannel.invokeMethod('stopWakeWordService');
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 350));
  }

  Future<void> _stopNativeSpeech() async {
    try {
      await _nativeSpeechChannel.invokeMethod<void>('stop');
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Lumin"),
        backgroundColor: Colors.black,
        actions: [
          IconButton(
            icon: const Icon(Icons.query_stats),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const MetricsScreen(),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.person),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const ProfileScreen(),
                ),
              );
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: Image.asset(
              'assets/images/background.png',
              fit: BoxFit.cover,
            ),
          ),
          Positioned.fill(
            child: Container(
              color: Colors.black.withOpacity(0.6),
            ),
          ),
          SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _listening ? Icons.hearing : Icons.mic_none,
                      color: _listening ? Colors.greenAccent : Colors.white70,
                      size: 56,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _status,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 22,
                        color: Colors.white,
                      ),
                    ),
                    if (_heard.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        _heard,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 16,
                          color: Colors.white70,
                        ),
                      ),
                    ],
                    const SizedBox(height: 40),
                    _featureButton(
                      context,
                      "Object Recognition",
                      Icons.camera_alt,
                      const ObjectDetectionScreen(autoListen: true),
                    ),
                    _featureButton(
                      context,
                      "Read Text",
                      Icons.document_scanner,
                      const OCRScreen(),
                    ),
                    _featureButton(
                      context,
                      "Web Search",
                      Icons.public,
                      const WebSearchScreen(),
                    ),
                    _featureButton(
                      context,
                      "Performance Metrics",
                      Icons.query_stats,
                      const MetricsScreen(),
                    ),
                    _featureButton(
                      context,
                      "Emergency Call",
                      Icons.call,
                      null,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _featureButton(
    BuildContext context,
    String text,
    IconData icon,
    Widget? page,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: ElevatedButton.icon(
        icon: Icon(icon, color: Colors.white),
        label: Text(text),
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(double.infinity, 60),
          backgroundColor: const Color.fromARGB(200, 2, 42, 77),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        onPressed: page == null
            ? null
            : () {
                unawaited(_openPage(page));
              },
      ),
    );
  }
}

