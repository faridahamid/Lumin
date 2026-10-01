import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class DepthEstimator {
  Future<List<DepthPrediction>?> estimateOnServer({
    required String url,
    required Uint8List imageBytes,
    required List<DepthRect> rects,
  }) async {
    if (url.trim().isEmpty || rects.isEmpty) {
      return null;
    }

    final response = await http
        .post(
          Uri.parse(url),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'imageBase64': base64Encode(imageBytes),
            'imageMimeType': 'image/jpeg',
            'boxes': rects.map((rect) => rect.toJson()).toList(),
          }),
        )
        .timeout(const Duration(seconds: 8));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      return null;
    }

    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final scores = decoded is Map ? decoded['scores'] : null;
    final proximities = decoded is Map ? decoded['proximities'] : null;
    if (scores is! List) {
      return null;
    }

    final predictions = <DepthPrediction>[];
    for (var i = 0; i < scores.length; i++) {
      final score = int.tryParse(scores[i].toString());
      if (score == null) {
        continue;
      }
      final proximity = proximities is List && i < proximities.length
          ? proximities[i].toString()
          : _proximityForScore(score);
      predictions.add(DepthPrediction(score: score, proximity: proximity));
    }

    return predictions;
  }
}

class DepthRect {
  const DepthRect({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;

  Map<String, double> toJson() => {
        'left': left,
        'top': top,
        'right': right,
        'bottom': bottom,
      };
}

class DepthPrediction {
  const DepthPrediction({
    required this.score,
    required this.proximity,
  });

  final int score;
  final String proximity;
}

String _proximityForScore(int score) {
  if (score <= 35) {
    return 'VERY CLOSE';
  }
  if (score <= 60) {
    return 'CLOSE';
  }
  if (score <= 100) {
    return 'MID';
  }
  return 'FAR';
}
