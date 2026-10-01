import 'dart:async';
import 'dart:convert';

import 'package:android_intent_plus/android_intent.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

import '../services/performance_metrics.dart';

class WebSearchScreen extends StatefulWidget {
  const WebSearchScreen({
    super.key,
    this.autoListen = true,
  });

  final bool autoListen;

  @override
  State<WebSearchScreen> createState() => _WebSearchScreenState();
}

class _WebSearchScreenState extends State<WebSearchScreen> {
  static const String _webSearchUrl = String.fromEnvironment(
    'LUMIN_WEB_SEARCH_URL',
    defaultValue: 'http://10.0.2.2:3000/web-search',
  );
  static const String _emulatorWebSearchUrl =
      'http://127.0.0.1:3000/web-search';
  static const String _voiceAssistantUrl = String.fromEnvironment(
    'LUMIN_VOICE_ASSISTANT_URL',
    defaultValue: 'http://10.0.2.2:3000/ask',
  );
  static const String _openAiTtsUrl = String.fromEnvironment(
    'LUMIN_OPENAI_TTS_URL',
    defaultValue: 'http://10.0.2.2:3000/tts-openai',
  );
  static const String _emulatorOpenAiTtsUrl =
      'http://127.0.0.1:3000/tts-openai';

  static const MethodChannel _serviceChannel = MethodChannel('lumin/service');
  static const MethodChannel _ttsChannel = MethodChannel('lumin/tts');
  static const MethodChannel _nativeSpeechChannel =
      MethodChannel('lumin/native_speech');

  final FlutterTts _tts = FlutterTts();
  final AudioPlayer _audioPlayer = AudioPlayer();

  bool _listening = false;
  bool _searching = false;
  bool _speaking = false;
  bool _disposed = false;

  String _status =
      '\u0627\u0641\u062a\u062d\u062a \u0627\u0644\u0628\u062d\u062b. \u0627\u0633\u0623\u0644 \u0639\u0646 \u0623\u064a \u0645\u0639\u0644\u0648\u0645\u0629 \u0645\u062d\u062a\u0627\u062c\u0629 \u062a\u062d\u062f\u064a\u062b.';
  String _question = '';
  String _answer = '';
  List<_WebCitation> _citations = const [];
  final List<Map<String, String>> _conversation = [];

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_audioPlayer.dispose());
    unawaited(_tts.stop());
    unawaited(_stopNativeSpeech());
    unawaited(_restartWakeWordService());
    super.dispose();
  }

  Future<void> _prepare() async {
    await Permission.microphone.request();
    await _configureTts();
    await _stopWakeWordService();
    if (widget.autoListen) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (mounted && !_disposed) {
        unawaited(_listenForQuestion());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Web Search'),
        backgroundColor: Colors.black87,
        centerTitle: true,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFF101820),
                  Color(0xFF0A0F12),
                ],
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _SearchAnswerCard(
                            status: _status,
                            question: _question,
                            answer: _answer,
                            searching: _searching,
                            listening: _listening,
                            speaking: _speaking,
                          ),
                          const SizedBox(height: 14),
                          if (_citations.isNotEmpty)
                            _SourcesPanel(
                              citations: _citations,
                              onOpen: _openCitation,
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _searching || _speaking || _listening
                              ? null
                              : () => unawaited(_listenForQuestion()),
                          icon: Icon(_listening ? Icons.hearing : Icons.mic),
                          label: Text(_listening ? 'Listening' : 'Ask'),
                          style: ElevatedButton.styleFrom(
                            minimumSize: const Size.fromHeight(56),
                            backgroundColor: Colors.greenAccent.shade700,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      IconButton.filled(
                        tooltip: 'Replay answer',
                        onPressed: _answer.trim().isEmpty ||
                                _searching ||
                                _speaking ||
                                _listening
                            ? null
                            : () => unawaited(_speak(_answer)),
                        icon: const Icon(Icons.volume_up),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _listenForQuestion() async {
    if (_listening || _searching || _speaking || _disposed) {
      return;
    }

    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      if (mounted) {
        setState(() => _status = 'Microphone permission is required');
      }
      return;
    }

    setState(() {
      _listening = true;
      _status = 'Listening for 4 seconds... ask what you want to search';
    });

    try {
      await _beep();
      final raw = await _recordAndTranscribe();
      final words = (raw['transcript'] ?? '').toString().trim();
      final error = (raw['error'] ?? '').toString().trim();

      if (!mounted || _disposed) {
        return;
      }

      setState(() => _listening = false);

      if (words.isEmpty) {
        setState(() {
          _status = error.isEmpty
              ? 'I did not hear clearly. Tap Ask and try again.'
              : 'Speech error: $error';
        });
        return;
      }

      if (_isBackCommand(words)) {
        Navigator.of(context).maybePop();
        return;
      }

      await _search(words);
    } catch (error) {
      if (mounted) {
        setState(() {
          _listening = false;
          _status = 'Speech failed: $error';
        });
      }
    }
  }

  Future<void> _search(String question) async {
    setState(() {
      _question = question;
      _answer = '';
      _citations = const [];
      _searching = true;
      _status = 'Searching the web...';
    });

    try {
      final stopwatch = Stopwatch()..start();
      final response = await _postJsonWithFallback(
        urls: _webSearchUrls(),
        body: {
          'question': question,
          'history': _conversation,
        },
        timeout: const Duration(seconds: 75),
      );
      PerformanceMetrics.logDuration('web_search_latency_ms', stopwatch);
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      final answer = (decoded['answer'] ?? '').toString().trim();
      final citations = _parseCitations(decoded['citations']);

      if (!mounted || _disposed) {
        return;
      }

      setState(() {
        _answer = answer;
        _citations = citations;
        _status = answer.isEmpty ? 'No answer returned.' : answer;
        _searching = false;
      });
      _rememberTurn(question, answer);

      await _speak(answer.isEmpty ? 'No answer returned.' : answer);
      _listenAgainSoon();
    } catch (error) {
      if (mounted) {
        setState(() {
          _answer = '';
          _citations = const [];
          _status = 'Search failed: $error';
          _searching = false;
        });
      }
    } finally {
      if (mounted) {
        setState(() => _searching = false);
      }
    }
  }

  Future<Map<String, String>> _recordAndTranscribe() async {
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
            'Backend $url returned ${response.statusCode}: ${response.body}';
      } catch (error) {
        lastError = '$url failed: $error';
      }
    }

    throw Exception(lastError ?? 'No backend URL worked');
  }

  List<_WebCitation> _parseCitations(Object? raw) {
    if (raw is! List) {
      return const [];
    }

    final citations = <_WebCitation>[];
    final seenUrls = <String>{};
    for (final item in raw) {
      if (item is! Map) {
        continue;
      }
      final title = (item['title'] ?? '').toString().trim();
      final url = (item['url'] ?? '').toString().trim();
      if (url.isEmpty || !seenUrls.add(url)) {
        continue;
      }
      citations.add(_WebCitation(title: title.isEmpty ? url : title, url: url));
    }
    return citations;
  }

  Future<void> _configureTts() async {
    await _tts.awaitSpeakCompletion(true);
    await _tts.setVolume(1.0);
    await _tts.setSpeechRate(0.42);
    await _tts.setPitch(1.0);
    await _tts.setLanguage('ar-EG');
  }

  Future<void> _speak(String text) async {
    if (_disposed || text.trim().isEmpty) {
      return;
    }

    setState(() => _speaking = true);
    await _stopNativeSpeech();

    try {
      if (await _speakWithOpenAiTts(text)) {
        return;
      }
      if (mounted) {
        setState(() {
          _status =
              'Answer is ready, but Lumin voice is unavailable right now.';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _speaking = false);
      }
    }
  }

  void _listenAgainSoon() {
    Future<void>.delayed(const Duration(milliseconds: 700), () {
      if (!mounted || _disposed || _listening || _searching || _speaking) {
        return;
      }
      unawaited(_listenForQuestion());
    });
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
        await _playAudioBytes(base64Decode(audioBase64));
        return true;
      } catch (error) {
        lastError = '$url failed: $error';
      }
    }

    debugPrint('Web Search OpenAI TTS fallback: $lastError');
    return false;
  }

  void _rememberTurn(String question, String answer) {
    final cleanQuestion = question.trim();
    final cleanAnswer = answer.trim();
    if (cleanQuestion.isEmpty || cleanAnswer.isEmpty) {
      return;
    }

    _conversation.add({'role': 'user', 'content': cleanQuestion});
    _conversation.add({'role': 'assistant', 'content': cleanAnswer});
    if (_conversation.length > 12) {
      _conversation.removeRange(0, _conversation.length - 12);
    }
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
      await completed.future.timeout(const Duration(seconds: 45));
    } on TimeoutException {
      // Continue if the audio plugin misses completion.
    } finally {
      await subscription.cancel();
    }
  }

  bool _isBackCommand(String words) {
    final text = words.toLowerCase();
    return text.contains('go back') ||
        text.contains('back to menu') ||
        text.contains('exit') ||
        text.contains('\u0631\u062c\u0648\u0639') ||
        text.contains('\u0627\u0631\u062c\u0639') ||
        text.contains('\u0627\u062e\u0631\u062c');
  }

  List<String> _webSearchUrls() => [
        _webSearchUrl,
        if (_webSearchUrl != _emulatorWebSearchUrl) _emulatorWebSearchUrl,
      ];

  Uri _transcribeUri() {
    final askUri = Uri.parse(_voiceAssistantUrl);
    final path = askUri.path.endsWith('/ask')
        ? askUri.path.substring(0, askUri.path.length - 4)
        : askUri.path;
    return askUri.replace(path: '$path/transcribe');
  }

  Uri _emulatorTranscribeUri() => Uri.parse('http://127.0.0.1:3000/transcribe');

  Future<void> _openCitation(_WebCitation citation) async {
    try {
      final intent = AndroidIntent(
        action: 'android.intent.action.VIEW',
        data: citation.url,
      );
      await intent.launch();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open source: ${citation.url}')),
        );
      }
    }
  }

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

class _SearchAnswerCard extends StatelessWidget {
  const _SearchAnswerCard({
    required this.status,
    required this.question,
    required this.answer,
    required this.searching,
    required this.listening,
    required this.speaking,
  });

  final String status;
  final String question;
  final String answer;
  final bool searching;
  final bool listening;
  final bool speaking;

  @override
  Widget build(BuildContext context) {
    final icon = searching
        ? Icons.travel_explore
        : listening
            ? Icons.hearing
            : speaking
                ? Icons.volume_up
                : Icons.public;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: Colors.white, size: 34),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  status,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          if (question.trim().isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              'You: $question',
              style: const TextStyle(color: Colors.white70, fontSize: 15),
            ),
          ],
          if (answer.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            SelectableText(
              answer,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SourcesPanel extends StatelessWidget {
  const _SourcesPanel({
    required this.citations,
    required this.onOpen,
  });

  final List<_WebCitation> citations;
  final ValueChanged<_WebCitation> onOpen;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.68),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Sources',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 8),
          for (final citation in citations)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextButton.icon(
                onPressed: () => onOpen(citation),
                icon: const Icon(Icons.open_in_new),
                label: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    citation.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _WebCitation {
  const _WebCitation({
    required this.title,
    required this.url,
  });

  final String title;
  final String url;
}
