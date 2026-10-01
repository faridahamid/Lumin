import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

class OpenAIRealtimeVoice {
  OpenAIRealtimeVoice({
    required this.sessionUrl,
    required this.onStatus,
    required this.onTranscript,
    required this.onError,
  });

  final String sessionUrl;
  final void Function(String status) onStatus;
  final void Function(String transcript) onTranscript;
  final void Function(Object error) onError;

  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  Completer<void>? _dataChannelOpen;
  bool _rendererReady = false;

  bool get isConnected => _peerConnection != null;

  Widget buildRemoteAudioSink() {
    return SizedBox(
      width: 1,
      height: 1,
      child: RTCVideoView(_remoteRenderer),
    );
  }

  Future<void> start({required List<String> sceneObjects}) async {
    if (isConnected) {
      return;
    }

    try {
      onStatus('Connecting to OpenAI voice...');
      if (!_rendererReady) {
        await _remoteRenderer.initialize();
        _rendererReady = true;
      }

      _peerConnection = await createPeerConnection({
        'sdpSemantics': 'unified-plan',
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
        ],
      });

      _peerConnection?.onConnectionState = (state) {
        onStatus('OpenAI voice: ${state.name}');
      };

      _peerConnection?.onTrack = (event) {
        if (event.streams.isNotEmpty) {
          _remoteStream = event.streams.first;
          _remoteRenderer.srcObject = _remoteStream;
          onStatus('OpenAI voice connected. Ask now.');
        }
      };

      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'video': false,
      });

      for (final track in _localStream!.getAudioTracks()) {
        await _peerConnection?.addTrack(track, _localStream!);
      }

      _dataChannelOpen = Completer<void>();
      _dataChannel = await _peerConnection?.createDataChannel(
        'oai-events',
        RTCDataChannelInit(),
      );
      _dataChannel?.onDataChannelState = (state) {
        if (state == RTCDataChannelState.RTCDataChannelOpen &&
            !(_dataChannelOpen?.isCompleted ?? true)) {
          _dataChannelOpen?.complete();
        }
      };
      _dataChannel?.onMessage = (message) {
        _handleServerEvent(message.text);
      };

      final offer = await _peerConnection!.createOffer({
        'mandatory': {
          'OfferToReceiveAudio': true,
          'OfferToReceiveVideo': false,
        },
        'optional': [],
      });
      await _peerConnection!.setLocalDescription(offer);
      final localDescription = await _peerConnection!.getLocalDescription();
      final offerSdp = _normalizeSdp(localDescription?.sdp ?? offer.sdp ?? '');
      if (offerSdp.isEmpty) {
        throw Exception('WebRTC created an empty SDP offer');
      }
      onStatus('Sending SDP offer (${offerSdp.length} chars)...');

      final response = await http
          .post(
            Uri.parse(sessionUrl),
            headers: const {
              'Content-Type': 'application/sdp',
              'Accept': 'application/sdp',
            },
            body: offerSdp,
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('Realtime backend returned ${response.statusCode}: '
            '${response.body} (sent SDP ${offerSdp.length} chars)');
      }

      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(response.body, 'answer'),
      );

      await _waitForDataChannel();
      _sendSceneContext(sceneObjects);
      onStatus('OpenAI voice is listening. Tap stop when finished.');
    } catch (error) {
      await stop();
      onError(error);
    }
  }

  String _normalizeSdp(String sdp) {
    final normalized = sdp
        .trim()
        .replaceAll('\r\n', '\n')
        .replaceAll('\n', '\r\n');
    return normalized.isEmpty ? '' : '$normalized\r\n';
  }

  Future<void> stop() async {
    final dataChannel = _dataChannel;
    final peerConnection = _peerConnection;
    final localStream = _localStream;
    final remoteStream = _remoteStream;

    _dataChannel = null;
    _peerConnection = null;
    _localStream = null;
    _remoteStream = null;
    _dataChannelOpen = null;
    _remoteRenderer.srcObject = null;

    await dataChannel?.close();
    await peerConnection?.close();

    if (localStream != null) {
      for (final track in localStream.getTracks()) {
        await track.stop();
      }
      await localStream.dispose();
    }

    await remoteStream?.dispose();
  }

  Future<void> dispose() async {
    await stop();
    if (_rendererReady) {
      await _remoteRenderer.dispose();
      _rendererReady = false;
    }
  }

  Future<void> _waitForDataChannel() async {
    final completer = _dataChannelOpen;
    if (completer == null) {
      return;
    }
    await completer.future.timeout(const Duration(seconds: 8));
  }

  void _sendSceneContext(List<String> sceneObjects) {
    final scene = sceneObjects.isEmpty
        ? 'No objects detected.'
        : sceneObjects.join(', ');
    _sendEvent({
      'type': 'session.update',
      'session': {
        'instructions':
            'You are Lumin, an Arabic voice assistant for a visually impaired '
                'person. Reply in short, clear Egyptian Arabic. Current camera '
                'context from the local YOLO model: $scene. Use this only as '
                'visual context when the user speaks. Do not respond to this '
                'context update. Wait silently for the user question.',
      },
    });
  }

  void _sendEvent(Map<String, Object?> event) {
    final channel = _dataChannel;
    if (channel == null) {
      return;
    }
    channel.send(RTCDataChannelMessage(jsonEncode(event)));
  }

  void _handleServerEvent(String raw) {
    try {
      final event = jsonDecode(raw);
      if (event is! Map<String, dynamic>) {
        return;
      }

      final type = event['type']?.toString() ?? '';
      final delta = event['delta'];
      final transcript = event['transcript'];

      if (type.contains('transcript') && delta is String && delta.isNotEmpty) {
        onTranscript(delta);
      } else if (type.contains('transcript') &&
          transcript is String &&
          transcript.isNotEmpty) {
        onTranscript(transcript);
      } else if (type == 'error') {
        onError(event['error'] ?? raw);
      }
    } catch (_) {
      // Ignore non-JSON or partial event payloads.
    }
  }
}
