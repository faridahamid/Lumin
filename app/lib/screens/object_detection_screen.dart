import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import '../realtime/openai_realtime_voice.dart';
import '../services/depth_estimator.dart';
import '../services/performance_metrics.dart';

class ObjectDetectionScreen extends StatefulWidget {
  const ObjectDetectionScreen({
    super.key,
    this.autoListen = false,
  });

  final bool autoListen;

  @override
  State<ObjectDetectionScreen> createState() => _ObjectDetectionScreenState();
}

class _ObjectDetectionScreenState extends State<ObjectDetectionScreen> {
  static const String _cocoModelPath = 'yolo26n_float32_final';
  static const String _customModelPath = 'lumin_best_float32';
  static const String _realtimeSessionUrl = String.fromEnvironment(
    'LUMIN_REALTIME_SESSION_URL',
    defaultValue: 'http://10.0.2.2:3000/realtime/session',
  );
  static const bool _useOpenAIRealtimeVoice = bool.fromEnvironment(
    'LUMIN_USE_OPENAI_REALTIME',
    defaultValue: false,
  );
  static const String _voiceAssistantUrl = String.fromEnvironment(
    'LUMIN_VOICE_ASSISTANT_URL',
    defaultValue: 'http://10.0.2.2:3000/ask',
  );
  static const String _emulatorVoiceAssistantUrl =
      'http://127.0.0.1:3000/ask';
  static const String _edgeTtsUrl = String.fromEnvironment(
    'LUMIN_EDGE_TTS_URL',
    defaultValue: 'http://10.0.2.2:3000/tts-edge',
  );
  static const String _emulatorEdgeTtsUrl = 'http://127.0.0.1:3000/tts-edge';
  static const String _openAiTtsUrl = String.fromEnvironment(
    'LUMIN_OPENAI_TTS_URL',
    defaultValue: 'http://10.0.2.2:3000/tts-openai',
  );
  static const String _emulatorOpenAiTtsUrl =
      'http://127.0.0.1:3000/tts-openai';
  static const String _midasDepthUrl = String.fromEnvironment(
    'LUMIN_MIDAS_DEPTH_URL',
    defaultValue: '',
  );
  static const MethodChannel _serviceChannel = MethodChannel('lumin/service');
  static const MethodChannel _ttsChannel = MethodChannel('lumin/tts');
  static const MethodChannel _nativeSpeechChannel =
      MethodChannel('lumin/native_speech');

  late final YOLO _customModel;
  late final DepthEstimator _depthEstimator;
  late final OpenAIRealtimeVoice _realtimeVoice;
  final FlutterTts _tts = FlutterTts();
  final AudioPlayer _audioPlayer = AudioPlayer();

  bool _customModelReady = false;
  bool _depthModelReady = false;
  bool _customInferenceRunning = false;
  bool _depthInferenceRunning = false;
  bool _speechReady = false;
  bool _listening = false;
  bool _nativeListening = false;
  bool _askingAssistant = false;
  bool _realtimeConnecting = false;
  bool _realtimeConnected = false;
  DateTime _lastCustomInference = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastDepthInference = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _fpsWindowStartedAt;
  int _fpsFrameCount = 0;

  List<_DetectionBox> _cocoDetections = [];
  List<_DetectionBox> _customDetections = [];
  String _currentObjectText = 'Loading models...';
  String _voiceStatus = 'Tap the mic and ask anything in Arabic';
  String _recognizedQuestion = '';
  String _lastAnswer = '';
  String _ttsStatus = '';

  @override
  void initState() {
    super.initState();
    _customModel = YOLO(
      modelPath: _customModelPath,
      task: YOLOTask.detect,
      useGpu: false,
      useMultiInstance: true,
    );
    _depthEstimator = DepthEstimator();
    _realtimeVoice = OpenAIRealtimeVoice(
      sessionUrl: _realtimeSessionUrl,
      onStatus: _handleRealtimeStatus,
      onTranscript: _handleRealtimeTranscript,
      onError: _handleRealtimeError,
    );
    unawaited(_loadCustomModel());
    unawaited(_loadDepthModel());
    if (_useOpenAIRealtimeVoice) {
      _voiceStatus = 'Tap the mic to start OpenAI voice';
      unawaited(_configureTts());
    } else {
      unawaited(_initVoice(startListening: widget.autoListen));
    }
  }

  Future<void> _loadCustomModel() async {
    final loaded = await _customModel.loadModel();
    if (!mounted) {
      return;
    }

    setState(() {
      _customModelReady = loaded;
      _currentObjectText = loaded ? 'Scanning...' : 'Custom model failed';
    });
  }

  Future<void> _loadDepthModel() async {
    if (!mounted) {
      return;
    }

    setState(() {
      _depthModelReady = _midasDepthUrl.trim().isNotEmpty;
    });
  }

  @override
  void dispose() {
    unawaited(_customModel.dispose());
    unawaited(_realtimeVoice.dispose());
    unawaited(_stopNativeSpeech());
    unawaited(_tts.stop());
    unawaited(_audioPlayer.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Visual Assistant'),
        backgroundColor: Colors.black87,
        centerTitle: true,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          YOLOView(
            modelPath: _cocoModelPath,
            task: YOLOTask.detect,
            useGpu: false,
            confidenceThreshold: 0.55,
            iouThreshold: 0.45,
            showOverlays: false,
            streamingConfig: const YOLOStreamingConfig(
              includeDetections: true,
              includeOriginalImage: true,
              includeProcessingTimeMs: false,
              includeFps: true,
              maxFPS: 8,
              inferenceFrequency: 8,
            ),
            onStreamingData: _processCocoStream,
          ),
          CustomPaint(
            painter: _DetectionOverlayPainter(
              cocoDetections: _cocoDetections,
              customDetections: _customDetections,
            ),
          ),
          Positioned(
            left: 0,
            bottom: 0,
            child: IgnorePointer(
              child: Opacity(
                opacity: 0,
                child: _realtimeVoice.buildRemoteAudioSink(),
              ),
            ),
          ),
          Positioned(
            top: 16,
            left: 16,
            right: 16,
            child: _StatusBar(
              customReady: _customModelReady,
              depthReady: _depthModelReady,
              customCount: _customDetections.length,
              cocoCount: _cocoDetections.length,
            ),
          ),
          Positioned(
            bottom: 30,
            left: 20,
            right: 20,
            child: _AssistantPanel(
              currentObjectText: _currentObjectText,
              voiceStatus: _voiceStatus,
              recognizedQuestion: _recognizedQuestion,
              lastAnswer: _lastAnswer,
              ttsStatus: _ttsStatus,
              canReplay: _lastAnswer.isNotEmpty,
              listening: _listening,
              askingAssistant: _askingAssistant || _realtimeConnecting,
              usingOpenAIVoice: _realtimeConnected,
              onMicPressed: _handleMicPressed,
              onReplayPressed: _replayLastAnswer,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _initVoice({bool startListening = false}) async {
    await Permission.microphone.request();
    _speechReady = true;
    await _configureTts();

    if (!mounted) {
      return;
    }

    setState(() {
      _voiceStatus = _speechReady
          ? widget.autoListen
              ? 'Listening... ask about what is ahead'
              : 'Tap the mic and ask in Arabic'
          : 'Speech recognition is not available';
    });

    if (startListening) {
      Future<void>.delayed(const Duration(milliseconds: 500), () {
        if (mounted && !_listening && !_askingAssistant) {
          unawaited(_handleMicPressed());
        }
      });
    }
  }

  Future<void> _handleMicPressed() async {
    if (_askingAssistant || _realtimeConnecting) {
      return;
    }

    if (_realtimeConnected) {
      await _realtimeVoice.stop();
      if (mounted) {
        setState(() {
          _realtimeConnected = false;
          _listening = false;
          _voiceStatus = 'OpenAI voice stopped';
        });
      }
      await _restartWakeWordService();
      return;
    }

    if (_listening) {
      await _stopNativeSpeech();
      if (mounted) {
        setState(() {
          _listening = false;
          _voiceStatus = 'Stopped listening';
        });
      }
      await _restartWakeWordService();
      return;
    }

    if (!_useOpenAIRealtimeVoice && !_speechReady) {
      await _initVoice();
      if (!_speechReady) {
        return;
      }
    }

    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      if (mounted) {
        setState(() {
          _voiceStatus = 'Microphone permission is required';
        });
      }
      return;
    }

    await _audioPlayer.stop();
    await _tts.stop();
    await _stopWakeWordService();

    if (_useOpenAIRealtimeVoice) {
      if (!mounted) {
        return;
      }

      setState(() {
        _recognizedQuestion = '';
        _lastAnswer = '';
        _ttsStatus = '';
        _listening = true;
        _realtimeConnecting = true;
        _voiceStatus = 'Connecting to OpenAI voice...';
      });

      await _realtimeVoice.start(sceneObjects: _sceneObjectDescriptions());
      return;
    }

    if (!mounted) {
      return;
    }

    await _listenWithNativeSpeechFallback();
  }

  Future<void> _listenWithNativeSpeechFallback() async {
    if (_nativeListening || _askingAssistant || _realtimeConnected) {
      return;
    }
    _nativeListening = true;
    try {
      await _audioPlayer.stop();
      await _tts.stop();
      await _stopWakeWordService();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!mounted) {
        return;
      }

      setState(() {
        _recognizedQuestion = '';
        _ttsStatus = '';
        _listening = true;
        _voiceStatus = widget.autoListen
            ? 'Listening for 4 seconds... ask your next question'
            : 'Listening for 4 seconds... ask your question';
      });

      final raw = await _recordAndTranscribe();
      final words = (raw['transcript'] ?? '').toString().trim();
      final error = (raw['error'] ?? '').toString().trim();

      if (!mounted) {
        return;
      }
      setState(() {
        _listening = false;
      });

      if (words.isNotEmpty) {
        setState(() {
          _recognizedQuestion = words;
          _voiceStatus = 'Getting answer...';
        });
        await _askVoiceAssistant(words);
        return;
      }

      setState(() {
        _voiceStatus = error.isEmpty
            ? 'I did not hear a question. Try again.'
            : 'Speech error: $error';
      });
      if (widget.autoListen) {
        _restartListeningSoon();
      } else {
        await _restartWakeWordService();
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _listening = false;
          _voiceStatus = 'Native speech failed: $error';
        });
      }
      await _restartWakeWordService();
    } finally {
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

  Future<void> _askVoiceAssistant(String question) async {
    if (_askingAssistant) {
      return;
    }

    setState(() {
      _askingAssistant = true;
      _listening = false;
      _voiceStatus = 'Getting answer...';
    });

    try {
      final stopwatch = Stopwatch()..start();
      final requestBody = jsonEncode({
        'question': question,
        'objects': _sceneObjectDescriptions(),
      });
      final response = await _postVoiceAssistantRequest(requestBody);
      PerformanceMetrics.logDuration('scene_answer_latency_ms', stopwatch);
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      final answer = (decoded['answer'] ?? '').toString().trim();
      if (answer.isEmpty) {
        throw Exception('No answer returned');
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _lastAnswer = answer;
        _voiceStatus = answer;
        _ttsStatus = '';
      });
      await _speak(answer);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _voiceStatus = 'Assistant failed: $error';
        _ttsStatus = '';
      });
    } finally {
      if (mounted) {
        setState(() {
          _askingAssistant = false;
        });
      }
      if (widget.autoListen) {
        _restartListeningSoon();
      } else {
        await _restartWakeWordService();
      }
    }
  }

  Future<http.Response> _postVoiceAssistantRequest(String requestBody) async {
    final urls = <String>[
      _voiceAssistantUrl,
      if (_voiceAssistantUrl != _emulatorVoiceAssistantUrl)
        _emulatorVoiceAssistantUrl,
    ];

    Object? lastError;
    for (final url in urls) {
      try {
        final response = await http
            .post(
              Uri.parse(url),
              headers: const {'Content-Type': 'application/json'},
              body: requestBody,
            )
            .timeout(const Duration(seconds: 20));
        if (response.statusCode >= 200 && response.statusCode < 300) {
          return response;
        }
        lastError = 'Backend $url returned ${response.statusCode}: '
            '${response.body}';
      } catch (error) {
        lastError = '$url failed: $error';
      }
    }

    throw Exception(lastError ?? 'No voice assistant URL worked');
  }

  void _handleRealtimeStatus(String status) {
    if (!mounted) {
      return;
    }

    setState(() {
      _voiceStatus = status;
      _realtimeConnecting = status.toLowerCase().contains('connecting');
      _realtimeConnected = _realtimeVoice.isConnected && !_realtimeConnecting;
      _listening = _realtimeVoice.isConnected;
    });
  }

  void _handleRealtimeTranscript(String transcript) {
    if (!mounted || transcript.trim().isEmpty) {
      return;
    }

    setState(() {
      _lastAnswer = '';
      _ttsStatus = 'OpenAI realtime audio';
      _voiceStatus = transcript.trim();
    });
  }

  void _handleRealtimeError(Object error) {
    if (!mounted) {
      return;
    }

    setState(() {
      _realtimeConnecting = false;
      _realtimeConnected = false;
      _listening = false;
      _voiceStatus = 'OpenAI voice failed: $error';
      _ttsStatus = '';
    });
    unawaited(_restartWakeWordService());
  }

  Future<void> _configureTts() async {
    await _tts.awaitSpeakCompletion(true);
    await _tts.setVolume(1.0);
    await _tts.setSpeechRate(0.42);
    await _tts.setPitch(1.0);

    final languages = await _tts.getLanguages;
    final languageCodes = languages is List
        ? languages.map((language) => language.toString()).toList()
        : const <String>[];

    final preferredLanguage = languageCodes.firstWhere(
      (language) => language.toLowerCase() == 'ar-eg',
      orElse: () => languageCodes.firstWhere(
        (language) => language.toLowerCase().startsWith('ar'),
        orElse: () => 'ar-EG',
      ),
    );

    await _tts.setLanguage(preferredLanguage);
  }

  Future<void> _speak(String text) async {
    if (mounted) {
      setState(() {
        _ttsStatus = 'Preparing OpenAI voice...';
      });
    }
    debugPrint('Lumin TTS requested: $text');

    if (await _speakWithOpenAiTts(text)) {
      return;
    }

    try {
      final nativeSpoke = await _ttsChannel.invokeMethod<bool>(
            'speakArabic',
            {'text': text},
          ) ??
          false;
      debugPrint('Lumin native TTS accepted: $nativeSpoke');
      if (nativeSpoke) {
        if (mounted) {
          setState(() {
            _ttsStatus = 'Voice sent to Android TTS + Flutter fallback';
          });
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    } catch (error) {
      debugPrint('Lumin native TTS failed: $error');
    }

    try {
      await _configureTts();
      await _tts.stop();
      await _tts.speak(text);
      if (mounted) {
        setState(() {
          _ttsStatus = 'Voice sent to Flutter TTS';
        });
      }
    } catch (_) {
      await _tts.speak(text);
    }
  }

  Future<bool> _speakWithOpenAiTts(String text) async {
    final urls = <String>[
      _openAiTtsUrl,
      if (_openAiTtsUrl != _emulatorOpenAiTtsUrl) _emulatorOpenAiTtsUrl,
    ];

    Object? lastError;
    for (final url in urls) {
      try {
        final response = await http
            .post(
              Uri.parse(url),
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode({'text': text}),
            )
            .timeout(const Duration(seconds: 20));

        if (response.statusCode < 200 || response.statusCode >= 300) {
          lastError = 'Backend $url returned ${response.statusCode}: '
              '${response.body}';
          continue;
        }

        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        final audioBase64 = (decoded['audioBase64'] ?? '').toString();
        if (audioBase64.isEmpty) {
          lastError = 'Backend $url returned no audio';
          continue;
        }

        await _tts.stop();
        await _playAudioBytes(base64Decode(audioBase64));
        if (mounted) {
          setState(() {
            _ttsStatus = 'OpenAI TTS voice';
          });
        }
        return true;
      } catch (error) {
        lastError = '$url failed: $error';
      }
    }

    debugPrint('Lumin OpenAI TTS fallback: $lastError');
    if (mounted) {
      setState(() {
        _ttsStatus = 'OpenAI voice unavailable, using local voice';
      });
    }
    return false;
  }

  Future<bool> _speakWithEdgeTts(String text) async {
    final urls = <String>[
      _edgeTtsUrl,
      if (_edgeTtsUrl != _emulatorEdgeTtsUrl) _emulatorEdgeTtsUrl,
    ];

    Object? lastError;
    for (final url in urls) {
      try {
        final response = await http
            .post(
              Uri.parse(url),
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode({'text': text}),
            )
            .timeout(const Duration(seconds: 8));

        if (response.statusCode < 200 || response.statusCode >= 300) {
          lastError = 'Backend $url returned ${response.statusCode}: '
              '${response.body}';
          continue;
        }

        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        final audioBase64 = (decoded['audioBase64'] ?? '').toString();
        if (audioBase64.isEmpty) {
          lastError = 'Backend $url returned no audio';
          continue;
        }

        await _tts.stop();
        await _playAudioBytes(base64Decode(audioBase64));
        if (mounted) {
          setState(() {
            _ttsStatus = 'Microsoft Salma neural voice';
          });
        }
        return true;
      } catch (error) {
        lastError = '$url failed: $error';
      }
    }

    debugPrint('Lumin Edge TTS fallback: $lastError');
    if (mounted) {
      setState(() {
        _ttsStatus = 'Neural voice unavailable, using local voice';
      });
    }
    return false;
  }

  Future<void> _playAudioBytes(Uint8List bytes) async {
    final completed = Completer<void>();
    late final StreamSubscription<void> subscription;
    subscription = _audioPlayer.onPlayerComplete.listen((_) {
      if (!completed.isCompleted) {
        completed.complete();
      }
    });

    await _audioPlayer.stop();
    await _audioPlayer.play(BytesSource(bytes));

    try {
      await completed.future.timeout(const Duration(seconds: 12));
    } on TimeoutException {
      // Avoid blocking the assistant forever if the player misses completion.
    } finally {
      await subscription.cancel();
    }
  }

  Future<void> _replayLastAnswer() async {
    final answer = _lastAnswer.trim();
    if (answer.isEmpty) {
      return;
    }
    try {
      await _ttsChannel.invokeMethod<bool>('beep');
    } catch (_) {}
    await _speak(answer);
  }

  Future<void> _stopWakeWordService() async {
    try {
      await _serviceChannel.invokeMethod('stopWakeWordService');
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 350));
  }

  Future<void> _restartWakeWordService() async {
    try {
      await _serviceChannel.invokeMethod('startWakeWordService');
    } catch (_) {}
  }

  Future<void> _stopNativeSpeech() async {
    try {
      await _nativeSpeechChannel.invokeMethod<void>('stop');
    } catch (_) {}
  }

  void _restartListeningSoon() {
    Future<void>.delayed(const Duration(milliseconds: 900), () async {
      if (!mounted ||
          _listening ||
          _askingAssistant ||
          _realtimeConnected) {
        return;
      }
      try {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      } catch (_) {}
      unawaited(_handleMicPressed());
    });
  }

  void _processCocoStream(Map<String, dynamic> data) {
    _logObjectDetectionFrame();
    final cocoBoxes = _parseBoxes(data['detections'] ?? data['boxes'], 'COCO');
    final imageBytes = data['originalImage'];

    if (mounted) {
      setState(() {
        _cocoDetections = cocoBoxes;
        _currentObjectText = _describeTopDetection();
      });
    }

    if (imageBytes is Uint8List) {
      unawaited(_runCustomModel(imageBytes));
      unawaited(_runDepthModel(imageBytes));
    }
  }

  void _logObjectDetectionFrame() {
    final now = DateTime.now();
    final startedAt = _fpsWindowStartedAt;
    if (startedAt == null) {
      _fpsWindowStartedAt = now;
      _fpsFrameCount = 1;
      return;
    }

    _fpsFrameCount += 1;
    final elapsedMs = now.difference(startedAt).inMilliseconds;
    if (elapsedMs >= 5000) {
      PerformanceMetrics.logValue(
        'object_detection_fps',
        _fpsFrameCount * 1000 / elapsedMs,
      );
      _fpsWindowStartedAt = now;
      _fpsFrameCount = 0;
    }
  }

  Future<void> _runCustomModel(Uint8List imageBytes) async {
    if (!_customModelReady || _customInferenceRunning) {
      return;
    }

    final now = DateTime.now();
    if (now.difference(_lastCustomInference).inMilliseconds < 250) {
      return;
    }

    _customInferenceRunning = true;
    _lastCustomInference = now;

    try {
      final result = await _customModel.predict(
        imageBytes,
        confidenceThreshold: 0.45,
        iouThreshold: 0.45,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _customDetections = _parseBoxes(
          result['detections'] ?? result['boxes'],
          'Indoor',
        );
        _currentObjectText = _describeTopDetection();
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _currentObjectText = 'Custom model error';
        });
      }
    } finally {
      _customInferenceRunning = false;
    }
  }

  Future<void> _runDepthModel(Uint8List imageBytes) async {
    if (!_depthModelReady || _depthInferenceRunning) {
      return;
    }

    final now = DateTime.now();
    if (now.difference(_lastDepthInference).inMilliseconds < 500) {
      return;
    }

    _depthInferenceRunning = true;
    _lastDepthInference = now;

    try {
      await _runServerDepthModel(imageBytes);
    } finally {
      _depthInferenceRunning = false;
    }
  }

  Future<void> _runServerDepthModel(Uint8List imageBytes) async {
    final cocoDetections = List<_DetectionBox>.from(_cocoDetections);
    final customDetections = List<_DetectionBox>.from(_customDetections);
    final allDetections = [...cocoDetections, ...customDetections];
    if (allDetections.isEmpty) {
      return;
    }

    final stopwatch = Stopwatch()..start();
    final predictions = await _depthEstimator.estimateOnServer(
      url: _midasDepthUrl,
      imageBytes: imageBytes,
      rects: allDetections
          .map(
            (detection) => DepthRect(
              left: detection.rect.left,
              top: detection.rect.top,
              right: detection.rect.right,
              bottom: detection.rect.bottom,
            ),
          )
          .toList(),
    );
    PerformanceMetrics.logDuration('depth_latency_ms', stopwatch);

    if (!mounted ||
        predictions == null ||
        predictions.length < allDetections.length) {
      return;
    }

    setState(() {
      _cocoDetections = _applyServerDepthScores(
        cocoDetections,
        predictions.take(cocoDetections.length).toList(),
      );
      _customDetections = _applyServerDepthScores(
        customDetections,
        predictions
            .skip(cocoDetections.length)
            .take(customDetections.length)
            .toList(),
      );
      _currentObjectText = _describeTopDetection();
    });
  }

  List<_DetectionBox> _applyServerDepthScores(
    List<_DetectionBox> detections,
    List<DepthPrediction> predictions,
  ) {
    final scored = <_DetectionBox>[];
    for (var index = 0; index < detections.length; index++) {
      final prediction = predictions[index];
      scored.add(
        detections[index].copyWith(
          depthScore: prediction.score,
          proximity: prediction.proximity,
        ),
      );
    }
    return scored;
  }

  List<_DetectionBox> _parseBoxes(Object? rawBoxes, String source) {
    if (rawBoxes is! List) {
      return const [];
    }

    final parsed = <_DetectionBox>[];
    for (final item in rawBoxes) {
      if (item is! Map) {
        continue;
      }

      final box = Map<String, dynamic>.from(item);
      final label = _readString(box, 'className') ?? _readString(box, 'class');
      final confidence = _readDouble(box, 'confidence');

      final normalizedBox = box['normalizedBox'];
      final left = normalizedBox is Map
          ? _readDouble(normalizedBox, 'left')
          : _readDouble(box, 'x1_norm');
      final top = normalizedBox is Map
          ? _readDouble(normalizedBox, 'top')
          : _readDouble(box, 'y1_norm');
      final right = normalizedBox is Map
          ? _readDouble(normalizedBox, 'right')
          : _readDouble(box, 'x2_norm');
      final bottom = normalizedBox is Map
          ? _readDouble(normalizedBox, 'bottom')
          : _readDouble(box, 'y2_norm');

      if (label == null ||
          confidence == null ||
          left == null ||
          top == null ||
          right == null ||
          bottom == null ||
          right <= left ||
          bottom <= top) {
        continue;
      }

      parsed.add(
        _DetectionBox(
          source: source,
          label: label,
          confidence: confidence,
          rect: Rect.fromLTRB(
            left.clamp(0.0, 1.0).toDouble(),
            top.clamp(0.0, 1.0).toDouble(),
            right.clamp(0.0, 1.0).toDouble(),
            bottom.clamp(0.0, 1.0).toDouble(),
          ),
        ),
      );
    }

    parsed.sort((a, b) => b.confidence.compareTo(a.confidence));
    return parsed.take(12).toList();
  }

  String _describeTopDetection() {
    final allDetections = [..._customDetections, ..._cocoDetections];
    if (allDetections.isEmpty) {
      return _customModelReady ? 'No object detected' : 'Loading custom model...';
    }

    allDetections.sort((a, b) => b.confidence.compareTo(a.confidence));
    final top = allDetections.first;
    final confidence = (top.confidence * 100).toStringAsFixed(0);
    final proximity = top.proximity == null ? '' : ' | ${top.proximity}';
    return '${top.source}: ${top.label} $confidence%$proximity';
  }

  List<String> _sceneObjectDescriptions() {
    final allDetections = [..._customDetections, ..._cocoDetections];
    allDetections.sort((a, b) => b.confidence.compareTo(a.confidence));

    return allDetections.take(10).map((detection) {
      final centerX = detection.rect.center.dx;
      final horizontal = centerX < 0.33
          ? 'left'
          : centerX > 0.66
              ? 'right'
              : 'center';
      final area = detection.rect.width * detection.rect.height;
      final distanceHint = detection.proximity?.toLowerCase() ??
          (area > 0.35
          ? 'very close'
          : area > 0.18
              ? 'close'
              : 'far');
      return '${detection.label} at $horizontal, $distanceHint';
    }).toSet().toList();
  }

  String? _readString(Map<dynamic, dynamic> map, String key) {
    final value = map[key];
    return value?.toString();
  }

  double? _readDouble(Map<dynamic, dynamic> map, String key) {
    final value = map[key];
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '');
  }
}

class _AssistantPanel extends StatelessWidget {
  const _AssistantPanel({
    required this.currentObjectText,
    required this.voiceStatus,
    required this.recognizedQuestion,
    required this.lastAnswer,
    required this.ttsStatus,
    required this.canReplay,
    required this.listening,
    required this.askingAssistant,
    required this.usingOpenAIVoice,
    required this.onMicPressed,
    required this.onReplayPressed,
  });

  final String currentObjectText;
  final String voiceStatus;
  final String recognizedQuestion;
  final String lastAnswer;
  final String ttsStatus;
  final bool canReplay;
  final bool listening;
  final bool askingAssistant;
  final bool usingOpenAIVoice;
  final VoidCallback onMicPressed;
  final VoidCallback onReplayPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.76),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  currentObjectText,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 20,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _assistantText(),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 64,
                height: 64,
                child: FloatingActionButton(
                  heroTag: 'arabicAssistantMic',
                  backgroundColor: listening
                      ? Colors.redAccent
                      : askingAssistant
                          ? Colors.orangeAccent
                          : Colors.greenAccent.shade700,
                  onPressed: askingAssistant ? null : onMicPressed,
                  child: askingAssistant
                      ? const SizedBox(
                          width: 26,
                          height: 26,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            color: Colors.black,
                          ),
                        )
                      : Icon(
                          listening ? Icons.stop : Icons.mic,
                          color: Colors.white,
                          size: 32,
                        ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: 48,
                height: 48,
                child: IconButton.filled(
                  tooltip: usingOpenAIVoice
                      ? 'OpenAI voice is live'
                      : 'Replay answer',
                  style: IconButton.styleFrom(
                    backgroundColor: usingOpenAIVoice
                        ? Colors.deepPurpleAccent
                        : canReplay
                        ? Colors.blueAccent
                        : Colors.white.withValues(alpha: 0.18),
                  ),
                  onPressed:
                      !usingOpenAIVoice && canReplay ? onReplayPressed : null,
                  icon: Icon(
                    usingOpenAIVoice ? Icons.graphic_eq : Icons.volume_up,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _assistantText() {
    final lines = <String>[];
    final question = recognizedQuestion.trim();
    final answer = lastAnswer.trim();
    final status = voiceStatus.trim();

    if (question.isNotEmpty) {
      lines.add('You: $question');
    }
    if (answer.isNotEmpty) {
      lines.add('Lumin: $answer');
    }
    if (status.isNotEmpty && status != question && status != answer) {
      lines.add(status);
    }
    if (ttsStatus.trim().isNotEmpty) {
      lines.add(ttsStatus.trim());
    }

    return lines.isEmpty ? voiceStatus : lines.join('\n');
  }
}

class _DetectionBox {
  const _DetectionBox({
    required this.source,
    required this.label,
    required this.confidence,
    required this.rect,
    this.depthScore,
    this.proximity,
  });

  final String source;
  final String label;
  final double confidence;
  final Rect rect;
  final int? depthScore;
  final String? proximity;

  _DetectionBox copyWith({int? depthScore, String? proximity}) {
    return _DetectionBox(
      source: source,
      label: label,
      confidence: confidence,
      rect: rect,
      depthScore: depthScore ?? this.depthScore,
      proximity: proximity ?? this.proximity,
    );
  }
}

class _DetectionOverlayPainter extends CustomPainter {
  const _DetectionOverlayPainter({
    required this.cocoDetections,
    required this.customDetections,
  });

  final List<_DetectionBox> cocoDetections;
  final List<_DetectionBox> customDetections;

  @override
  void paint(Canvas canvas, Size size) {
    for (final detection in cocoDetections) {
      _drawDetection(canvas, size, detection, Colors.lightBlueAccent);
    }

    for (final detection in customDetections) {
      _drawDetection(canvas, size, detection, Colors.orangeAccent);
    }
  }

  void _drawDetection(
      Canvas canvas,
      Size size,
      _DetectionBox detection,
      Color color,
      ) {
    final rect = Rect.fromLTRB(
      detection.rect.left * size.width,
      detection.rect.top * size.height,
      detection.rect.right * size.width,
      detection.rect.bottom * size.height,
    );

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(8)),
      paint,
    );

    final depthText = detection.proximity == null
        ? ''
        : ' | ${detection.proximity} ${detection.depthScore}';
    final label =
        '${detection.source}: ${detection.label} ${(detection.confidence * 100).toStringAsFixed(0)}%$depthText';
    final textPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width - 24);

    final labelWidth = textPainter.width + 12;
    final labelHeight = textPainter.height + 8;
    final labelLeft = rect.left
        .clamp(0.0, size.width - labelWidth)
        .toDouble();
    final labelTop = (rect.top - labelHeight)
        .clamp(0.0, size.height - labelHeight)
        .toDouble();
    final labelRect = Rect.fromLTWH(labelLeft, labelTop, labelWidth, labelHeight);

    canvas.drawRRect(
      RRect.fromRectAndRadius(labelRect, const Radius.circular(6)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.75)
        ..style = PaintingStyle.fill,
    );

    textPainter.paint(canvas, Offset(labelLeft + 6, labelTop + 4));
  }

  @override
  bool shouldRepaint(covariant _DetectionOverlayPainter oldDelegate) {
    return oldDelegate.cocoDetections != cocoDetections ||
        oldDelegate.customDetections != customDetections;
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.customReady,
    required this.depthReady,
    required this.customCount,
    required this.cocoCount,
  });

  final bool customReady;
  final bool depthReady;
  final int customCount;
  final int cocoCount;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.center,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          'COCO $cocoCount  |  Indoor ${customReady ? customCount : 'loading'}  |  Depth ${depthReady ? 'on' : 'loading'}',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
