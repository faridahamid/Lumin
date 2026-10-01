import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import '../services/performance_metrics.dart';

class OCRScreen extends StatefulWidget {
  const OCRScreen({super.key});

  @override
  State<OCRScreen> createState() => _OCRScreenState();
}

class _OCRScreenState extends State<OCRScreen> {
  static const String _modelPath = 'yolo26n_float32_final';
  static const String _readTextUrl = String.fromEnvironment(
    'LUMIN_READ_TEXT_URL',
    defaultValue: 'http://10.0.2.2:3000/read-text',
  );
  static const String _emulatorReadTextUrl = 'http://127.0.0.1:3000/read-text';
  static const String _openAiTtsUrl = String.fromEnvironment(
    'LUMIN_OPENAI_TTS_URL',
    defaultValue: 'http://10.0.2.2:3000/tts-openai',
  );
  static const String _emulatorOpenAiTtsUrl =
      'http://127.0.0.1:3000/tts-openai';
  static const String _voiceAssistantUrl = String.fromEnvironment(
    'LUMIN_VOICE_ASSISTANT_URL',
    defaultValue: 'http://10.0.2.2:3000/ask',
  );
  static const MethodChannel _serviceChannel = MethodChannel('lumin/service');
  static const MethodChannel _ttsChannel = MethodChannel('lumin/tts');
  static const MethodChannel _nativeSpeechChannel = MethodChannel(
    'lumin/native_speech',
  );

  final FlutterTts _tts = FlutterTts();
  final AudioPlayer _audioPlayer = AudioPlayer();
  static const String _initialStatus =
      '\u0627\u0641\u062a\u062d\u062a \u0642\u0631\u0627\u0621\u0629 \u0627\u0644\u0646\u0635. \u062b\u0628\u062a \u0627\u0644\u0643\u0627\u0645\u064a\u0631\u0627.';
  static const String _holdSteadyStatus =
      '\u062b\u0628\u062a \u0627\u0644\u0643\u0627\u0645\u064a\u0631\u0627. \u0647\u062d\u0627\u0648\u0644 \u0623\u0642\u0631\u0623 \u0627\u0644\u0646\u0635.';
  static const String _readingStatus =
      '\u0628\u0642\u0631\u0623 \u0627\u0644\u0646\u0635...';
  static const String _listeningStatus =
      '\u0628\u0633\u0645\u0639\u0643. \u0627\u0633\u0623\u0644 \u0639\u0646 \u0627\u0644\u0646\u0635\u060c \u0623\u0648 \u0642\u0648\u0644 \u0627\u0644\u0635\u0641\u062d\u0629 \u0627\u0644\u0644\u064a \u0628\u0639\u062f\u0647\u0627\u060c \u0623\u0648 \u0627\u0631\u062c\u0639.';
  static const String _noTextMessage =
      '\u0645\u0634 \u0644\u0627\u0642\u064a \u0646\u0635 \u0648\u0627\u0636\u062d \u062f\u0644\u0648\u0642\u062a\u064a. \u062b\u0628\u062a \u0627\u0644\u0643\u0627\u0645\u064a\u0631\u0627 \u0648\u0647\u062d\u0627\u0648\u0644 \u062a\u0627\u0646\u064a.';
  static const String _captureNextMessage =
      '\u0647\u062d\u0627\u0648\u0644 \u0623\u0642\u0631\u0623 \u0627\u0644\u0635\u0641\u062d\u0629 \u0627\u0644\u0644\u064a \u0628\u0639\u062f\u0647\u0627.';
  static const String _genericReadFailure =
      '\u062d\u0635\u0644\u062a \u0645\u0634\u0643\u0644\u0629 \u0648\u0623\u0646\u0627 \u0628\u0642\u0631\u0623. \u0647\u062d\u0627\u0648\u0644 \u062a\u0627\u0646\u064a.';
  static const String _genericQuestionFailure =
      '\u0645\u0639\u0631\u0641\u062a\u0634 \u0623\u062c\u0627\u0648\u0628 \u0639\u0644\u0649 \u0627\u0644\u0633\u0624\u0627\u0644. \u0645\u0645\u0643\u0646 \u062a\u0633\u0623\u0644 \u062a\u0627\u0646\u064a.';

  Uint8List? _latestFrame;
  Timer? _autoCaptureTimer;
  DateTime _openedAt = DateTime.now();
  bool _captureQueued = true;
  bool _processing = false;
  bool _listening = false;
  bool _speaking = false;
  bool _disposed = false;

  String _status = _initialStatus;
  String _capturedText = '';
  String _lastAnswer = '';
  Map<String, dynamic> _rawOcr = const {};
  final List<String> _capturedPages = [];

  @override
  void initState() {
    super.initState();
    _openedAt = DateTime.now();
    unawaited(_prepareHandsFreeFlow());
  }

  @override
  void dispose() {
    _disposed = true;
    _autoCaptureTimer?.cancel();
    unawaited(_audioPlayer.dispose());
    unawaited(_tts.stop());
    unawaited(_stopNativeSpeech());
    unawaited(_restartWakeWordService());
    super.dispose();
  }

  Future<void> _prepareHandsFreeFlow() async {
    await Permission.camera.request();
    await Permission.microphone.request();
    await _configureTts();
    await _stopWakeWordService();
    await _beep();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Read Text'),
        backgroundColor: Colors.black87,
        centerTitle: true,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          YOLOView(
            modelPath: _modelPath,
            task: YOLOTask.detect,
            useGpu: false,
            showOverlays: false,
            streamingConfig: const YOLOStreamingConfig(
              includeDetections: false,
              includeOriginalImage: true,
              includeProcessingTimeMs: false,
              includeFps: false,
              maxFPS: 4,
              inferenceFrequency: 4,
            ),
            onStreamingData: _handleCameraFrame,
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: _ReadTextPanel(
              status: _status,
              lastAnswer: _lastAnswer,
              capturedText: _capturedText,
              processing: _processing,
              listening: _listening,
              speaking: _speaking,
              onReadAgain: _queueCapture,
              onReplay: _lastAnswer.trim().isEmpty
                  ? null
                  : () => unawaited(_speakThenListen(_lastAnswer)),
            ),
          ),
        ],
      ),
    );
  }

  void _handleCameraFrame(Map<String, dynamic> data) {
    final imageBytes = data['originalImage'];
    if (imageBytes is! Uint8List) {
      return;
    }

    _latestFrame = imageBytes;
    if (!_captureQueued || _processing || _listening || _speaking) {
      return;
    }

    if (DateTime.now().difference(_openedAt).inMilliseconds < 650) {
      return;
    }

    _captureQueued = false;
    unawaited(_captureAndRead(imageBytes));
  }

  void _queueCapture({
    String status = _holdSteadyStatus,
    Duration delay = const Duration(milliseconds: 700),
  }) {
    if (_processing || _speaking || _listening) {
      return;
    }
    _autoCaptureTimer?.cancel();
    setState(() {
      _status = status;
      _captureQueued = true;
      _openedAt = DateTime.now();
    });
    final frame = _latestFrame;
    if (frame != null) {
      Future<void>.delayed(delay, () {
        if (mounted && _captureQueued && !_processing) {
          _captureQueued = false;
          unawaited(_captureAndRead(frame));
        }
      });
    }
  }

  Future<void> _captureAndRead(Uint8List imageBytes) async {
    if (_processing || _disposed) {
      return;
    }

    setState(() {
      _processing = true;
      _listening = false;
      _status = _readingStatus;
      _lastAnswer = '';
    });

    try {
      await _beep();
      final stopwatch = Stopwatch()..start();
      final response = await _postJsonWithFallback(
        urls: _readTextUrls(),
        body: {
          'imageBase64': base64Encode(imageBytes),
          'imageMimeType': 'image/jpeg',
        },
        timeout: const Duration(seconds: 60),
      );
      PerformanceMetrics.logDuration('ocr_latency_ms', stopwatch);
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      final answer = (decoded['answer'] ?? '').toString().trim();
      final fullText = (decoded['fullText'] ?? '').toString().trim();
      final rawOcr = decoded['rawOcr'];

      if (!mounted) {
        return;
      }

      if (fullText.isEmpty) {
        setState(() {
          _capturedText = '';
          _lastAnswer = _noTextMessage;
          _status = _noTextMessage;
          _processing = false;
        });
        await _speakOnly(_noTextMessage);
        _scheduleAutoCapture();
        return;
      }

      setState(() {
        _capturedText = fullText;
        _rawOcr = rawOcr is Map<String, dynamic> ? rawOcr : const {};
        _lastAnswer = answer;
        _status = answer.isEmpty ? _noTextMessage : answer;
        _processing = false;
        _capturedPages.add(fullText);
      });
      await _speakThenListen(answer.isEmpty ? _noTextMessage : answer);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = _genericReadFailure;
        _lastAnswer = _genericReadFailure;
        _processing = false;
      });
      await _speakOnly(_genericReadFailure);
      _scheduleAutoCapture();
    } finally {
      if (mounted) {
        setState(() => _processing = false);
      }
    }
  }

  Future<void> _speakOnly(String text) async {
    if (_disposed || text.trim().isEmpty) {
      return;
    }

    setState(() {
      _speaking = true;
      _listening = false;
    });
    await _stopNativeSpeech();

    try {
      await _speak(text);
    } finally {
      if (mounted) {
        setState(() => _speaking = false);
      }
    }
  }

  Future<void> _speakThenListen(String text) async {
    if (_disposed || text.trim().isEmpty) {
      return;
    }

    setState(() {
      _speaking = true;
      _listening = false;
    });
    await _stopNativeSpeech();

    try {
      await _speak(text);
    } finally {
      if (mounted) {
        setState(() => _speaking = false);
      }
    }

    if (mounted && !_disposed) {
      await _listenForFollowUp();
    }
  }

  Future<void> _listenForFollowUp() async {
    if (_listening || _processing || _speaking || _disposed) {
      return;
    }

    setState(() {
      _listening = true;
      _status = _listeningStatus;
    });

    try {
      await _beep();
      final raw = await _recordAndTranscribe();
      final words = (raw['transcript'] ?? '').toString().trim();

      if (!mounted || _disposed) {
        return;
      }
      setState(() => _listening = false);

      if (words.isEmpty) {
        setState(() {
          _status = _captureNextMessage;
        });
        _scheduleAutoCapture();
        return;
      }

      if (_isBackCommand(words)) {
        Navigator.of(context).maybePop();
        return;
      }

      if (_isReadAgainCommand(words) || _isNextPageCommand(words)) {
        _queueCapture();
        return;
      }

      await _answerQuestion(words);
    } catch (error) {
      if (mounted) {
        setState(() {
          _listening = false;
          _status = _captureNextMessage;
        });
      }
      _scheduleAutoCapture();
    }
  }

  Future<void> _answerQuestion(String question) async {
    final readingContext = _readingContext();
    if (readingContext.trim().isEmpty) {
      await _speakOnly(_noTextMessage);
      _scheduleAutoCapture();
      return;
    }

    setState(() {
      _processing = true;
      _status = 'Answering: $question';
    });

    try {
      final stopwatch = Stopwatch()..start();
      final response = await _postJsonWithFallback(
        urls: _questionUrls(),
        body: {
          'question': question,
          'fullText': readingContext,
          'rawOcr': _rawOcr,
        },
        timeout: const Duration(seconds: 45),
      );
      PerformanceMetrics.logDuration('ocr_question_latency_ms', stopwatch);
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      final answer = (decoded['answer'] ?? '').toString().trim();
      if (!mounted) {
        return;
      }
      setState(() {
        _lastAnswer = answer;
        _status = answer;
        _processing = false;
      });
      await _speakThenListen(answer);
    } catch (error) {
      if (mounted) {
        setState(() {
          _lastAnswer = _genericQuestionFailure;
          _status = _genericQuestionFailure;
          _processing = false;
        });
        await _speakThenListen(_genericQuestionFailure);
      }
    } finally {
      if (mounted) {
        setState(() => _processing = false);
      }
    }
  }

  Future<Map<String, String>> _recordAndTranscribe() async {
    final recording = await _nativeSpeechChannel
        .invokeMethod<Map<dynamic, dynamic>>('recordWav', {
          'durationMillis': 4000,
        });
    final recordError = (recording?['error'] ?? '').toString().trim();
    if (recordError.isNotEmpty) {
      return {'error': recordError};
    }

    final audioBase64 = (recording?['audioBase64'] ?? '').toString();
    final audioMimeType = (recording?['audioMimeType'] ?? 'audio/wav')
        .toString();
    final max = int.tryParse((recording?['max'] ?? '0').toString()) ?? 0;
    if (audioBase64.isEmpty) {
      return {'error': 'empty_recording'};
    }
    if (max < 150) {
      return {'error': 'recorded_audio_too_quiet'};
    }

    final stopwatch = Stopwatch()..start();
    final response = await _postJsonWithFallback(
      urls: [_transcribeUri().toString(), _emulatorTranscribeUri().toString()],
      body: {
        'audioBase64': audioBase64,
        'audioMimeType': audioMimeType,
        'language': '',
      },
      timeout: const Duration(seconds: 45),
    );
    PerformanceMetrics.logDuration('transcription_latency_ms', stopwatch);

    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    return {'transcript': (decoded['text'] ?? '').toString()};
  }

  Future<http.Response> _postJsonWithFallback({
    required List<String> urls,
    required Map<String, Object?> body,
    required Duration timeout,
  }) async {
    Object? lastError;
    for (final url in urls.toSet()) {
      try {
        final response = await http
            .post(
              Uri.parse(url),
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode(body),
            )
            .timeout(timeout);
        if (response.statusCode >= 200 && response.statusCode < 300) {
          return response;
        }
        lastError =
            'Backend $url returned ${response.statusCode}: '
            '${response.body}';
      } catch (error) {
        lastError = '$url failed: $error';
      }
    }

    throw Exception(lastError ?? 'No backend URL worked');
  }

  Future<void> _configureTts() async {
    await _tts.awaitSpeakCompletion(true);
    await _tts.setVolume(1.0);
    await _tts.setSpeechRate(0.42);
    await _tts.setPitch(1.0);
    await _tts.setLanguage('ar-EG');
  }

  Future<void> _speak(String text) async {
    if (await _speakWithOpenAiTts(text)) {
      return;
    }

    final language = _languageForText(text);
    if (language == 'ar-EG') {
      try {
        await _ttsChannel.invokeMethod<bool>('speakArabic', {'text': text});
        await Future<void>.delayed(const Duration(milliseconds: 250));
      } catch (_) {}
    }

    try {
      await _configureTtsForLanguage(language);
      await _tts.stop();
      await _tts.speak(text);
    } catch (_) {
      await _tts.speak(text);
    }
  }

  Future<bool> _speakWithOpenAiTts(String text) async {
    Object? lastError;
    for (final url in {_openAiTtsUrl, _emulatorOpenAiTtsUrl}) {
      try {
        final response = await http
            .post(
              Uri.parse(url),
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode({'text': text}),
            )
            .timeout(const Duration(seconds: 25));
        if (response.statusCode < 200 || response.statusCode >= 300) {
          lastError = 'Backend $url returned ${response.statusCode}';
          continue;
        }

        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        final audioBase64 = (decoded['audioBase64'] ?? '').toString();
        if (audioBase64.isEmpty) {
          lastError = 'Backend $url returned no audio';
          continue;
        }

        await _tts.stop();
        await _playAudioBytes(
          base64Decode(audioBase64),
          timeout: _playbackTimeoutFor(text),
        );
        return true;
      } catch (error) {
        lastError = '$url failed: $error';
      }
    }

    debugPrint('Read Text OpenAI TTS fallback: $lastError');
    return false;
  }

  Future<void> _playAudioBytes(
    Uint8List bytes, {
    required Duration timeout,
  }) async {
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
      await completed.future.timeout(timeout);
    } on TimeoutException {
      // Let the flow continue if the player misses its completion callback.
    } finally {
      await subscription.cancel();
    }
  }

  void _scheduleAutoCapture({
    Duration delay = const Duration(milliseconds: 1400),
  }) {
    _autoCaptureTimer?.cancel();
    _autoCaptureTimer = Timer(delay, () {
      if (!mounted || _disposed || _processing || _speaking || _listening) {
        return;
      }
      _queueCapture(status: _captureNextMessage);
    });
  }

  Duration _playbackTimeoutFor(String text) {
    final seconds = (text.length / 8).ceil().clamp(45, 300);
    return Duration(seconds: seconds);
  }

  bool _isBackCommand(String words) {
    final text = words.toLowerCase();
    return text.contains('go back') ||
        text.contains('back to menu') ||
        text.contains('exit') ||
        text.contains('رجوع') ||
        text.contains('ارجع') ||
        text.contains('اخرج');
  }

  bool _isReadAgainCommand(String words) {
    final text = words.toLowerCase();
    return text.contains('read again') ||
        text.contains('scan again') ||
        text.contains('capture again') ||
        text.contains('try again') ||
        text.contains('اقرا تاني') ||
        text.contains('اقرأ تاني') ||
        text.contains('صور تاني');
  }

  bool _isNextPageCommand(String words) {
    final text = words.toLowerCase();
    return text.contains('next page') ||
        text.contains('another page') ||
        text.contains('new page') ||
        text.contains('add page') ||
        text.contains('continue reading') ||
        text.contains(
          '\u0627\u0644\u0635\u0641\u062d\u0629 \u0627\u0644\u0644\u064a \u0628\u0639\u062f\u0647\u0627',
        ) ||
        text.contains(
          '\u0627\u0644\u0635\u0641\u062d\u0647 \u0627\u0644\u0644\u064a \u0628\u0639\u062f\u0647\u0627',
        ) ||
        text.contains('\u0643\u0645\u0644') ||
        text.contains(
          '\u0627\u0644\u0644\u064a \u0628\u0639\u062f\u0647\u0627',
        );
  }

  String _readingContext() {
    if (_capturedPages.isEmpty) {
      return _capturedText;
    }

    final buffer = StringBuffer();
    for (var index = 0; index < _capturedPages.length; index += 1) {
      buffer.writeln('Page ${index + 1}:');
      buffer.writeln(_capturedPages[index]);
      buffer.writeln();
    }
    return buffer.toString().trim();
  }

  Future<void> _configureTtsForLanguage(String language) async {
    await _tts.awaitSpeakCompletion(true);
    await _tts.setVolume(1.0);
    await _tts.setSpeechRate(language == 'ar-EG' ? 0.42 : 0.46);
    await _tts.setPitch(1.0);
    await _tts.setLanguage(language);
  }

  String _languageForText(String text) {
    var arabic = 0;
    var latin = 0;
    final lowerText = ' ${text.toLowerCase()} ';
    for (final codeUnit in text.codeUnits) {
      if ((codeUnit >= 0x0600 && codeUnit <= 0x06FF) ||
          (codeUnit >= 0x0750 && codeUnit <= 0x077F) ||
          (codeUnit >= 0x08A0 && codeUnit <= 0x08FF)) {
        arabic += 1;
      } else if ((codeUnit >= 65 && codeUnit <= 90) ||
          (codeUnit >= 97 && codeUnit <= 122)) {
        latin += 1;
      }
    }

    if (latin > arabic && _looksFrench(lowerText)) {
      return 'fr-FR';
    }
    return arabic >= latin ? 'ar-EG' : 'en-US';
  }

  bool _looksFrench(String lowerText) {
    if (RegExp(r'[àâçéèêëîïôùûüÿœæ]').hasMatch(lowerText)) {
      return true;
    }

    final markers = [
      ' le ',
      ' la ',
      ' les ',
      ' des ',
      ' une ',
      ' est ',
      ' avec ',
      ' pour ',
      ' dans ',
      ' chapitre ',
      ' monsieur ',
      ' madame ',
    ];
    return markers.where(lowerText.contains).length >= 3;
  }

  List<String> _readTextUrls() => [
    _readTextUrl,
    if (_readTextUrl != _emulatorReadTextUrl) _emulatorReadTextUrl,
  ];

  List<String> _questionUrls() => _readTextUrls()
      .map(
        (url) => url.endsWith('/read-text')
            ? '${url.substring(0, url.length - '/read-text'.length)}/read-text/question'
            : '$url/question',
      )
      .toList();

  Uri _transcribeUri() {
    final askUri = Uri.parse(_voiceAssistantUrl);
    final path = askUri.path.endsWith('/ask')
        ? askUri.path.substring(0, askUri.path.length - 4)
        : askUri.path;
    return askUri.replace(path: '$path/transcribe');
  }

  Uri _emulatorTranscribeUri() => Uri.parse('http://127.0.0.1:3000/transcribe');

  Future<void> _beep() async {
    try {
      await _ttsChannel.invokeMethod<bool>('beep');
    } catch (_) {}
  }

  Future<void> _stopWakeWordService() async {
    try {
      await _serviceChannel.invokeMethod('stopWakeWordService');
    } catch (_) {}
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
}

class _ReadTextPanel extends StatelessWidget {
  const _ReadTextPanel({
    required this.status,
    required this.lastAnswer,
    required this.capturedText,
    required this.processing,
    required this.listening,
    required this.speaking,
    required this.onReadAgain,
    required this.onReplay,
  });

  final String status;
  final String lastAnswer;
  final String capturedText;
  final bool processing;
  final bool listening;
  final bool speaking;
  final VoidCallback onReadAgain;
  final VoidCallback? onReplay;

  @override
  Widget build(BuildContext context) {
    final icon = processing
        ? Icons.document_scanner
        : listening
        ? Icons.hearing
        : speaking
        ? Icons.volume_up
        : Icons.text_snippet;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.white, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  status,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (capturedText.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    capturedText,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            tooltip: 'Read again',
            onPressed: processing || speaking || listening ? null : onReadAgain,
            icon: const Icon(Icons.refresh),
          ),
          IconButton.filled(
            tooltip: 'Replay',
            onPressed: processing || speaking || listening ? null : onReplay,
            icon: const Icon(Icons.volume_up),
          ),
        ],
      ),
    );
  }
}
