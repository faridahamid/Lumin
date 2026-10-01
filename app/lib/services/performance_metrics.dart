import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PerformanceMetrics {
  const PerformanceMetrics._();

  static const String _metricNamesKey = 'lumin_metric_names';
  static const String _metricPrefix = 'lumin_metric_samples_';

  static void logDuration(String name, Stopwatch stopwatch) {
    if (stopwatch.isRunning) {
      stopwatch.stop();
    }
    _log(name, stopwatch.elapsedMilliseconds.toDouble());
  }

  static void logValue(String name, num value) {
    _log(name, value.toDouble());
  }

  static Future<List<MetricSummary>> summaries() async {
    final prefs = await SharedPreferences.getInstance();
    final names = (prefs.getStringList(_metricNamesKey) ?? [])..sort();
    return names.map((name) {
      final values = _readValues(prefs, name);
      return MetricSummary(name: name, values: values);
    }).where((summary) => summary.values.isNotEmpty).toList();
  }

  static Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    final names = prefs.getStringList(_metricNamesKey) ?? [];
    for (final name in names) {
      await prefs.remove('$_metricPrefix$name');
    }
    await prefs.remove(_metricNamesKey);
  }

  static void _log(String name, double value) {
    debugPrint('LUMIN_METRIC name=$name value=${value.toStringAsFixed(2)}');
    _saveSample(name, value);
  }

  static Future<void> _saveSample(String name, double value) async {
    final prefs = await SharedPreferences.getInstance();
    final names = prefs.getStringList(_metricNamesKey) ?? [];
    if (!names.contains(name)) {
      names.add(name);
      names.sort();
      await prefs.setStringList(_metricNamesKey, names);
    }

    final key = '$_metricPrefix$name';
    final values = prefs.getStringList(key) ?? [];
    values.add(value.toStringAsFixed(2));
    if (values.length > 100) {
      values.removeRange(0, values.length - 100);
    }
    await prefs.setStringList(key, values);
  }

  static List<double> _readValues(SharedPreferences prefs, String name) {
    final rawValues = prefs.getStringList('$_metricPrefix$name') ?? [];
    return rawValues
        .map(double.tryParse)
        .whereType<double>()
        .toList(growable: false);
  }
}

class MetricSummary {
  const MetricSummary({
    required this.name,
    required this.values,
  });

  final String name;
  final List<double> values;

  int get count => values.length;

  double get average => values.reduce((a, b) => a + b) / values.length;

  double get minimum => values.reduce((a, b) => a < b ? a : b);

  double get maximum => values.reduce((a, b) => a > b ? a : b);

  bool get isLatency => name.endsWith('_ms');

  bool get isFps => name.endsWith('_fps');

  String get title {
    switch (name) {
      case 'object_detection_fps':
        return 'Object Detection FPS';
      case 'ocr_latency_ms':
        return 'OCR Latency';
      case 'ocr_question_latency_ms':
        return 'OCR Question Latency';
      case 'transcription_latency_ms':
        return 'Transcription Latency';
      case 'web_search_latency_ms':
        return 'Web Search Latency';
      case 'depth_latency_ms':
        return 'Depth Estimation Latency';
      case 'scene_answer_latency_ms':
        return 'Scene Answer Latency';
      default:
        return name;
    }
  }

  String format(double value) {
    if (isLatency) {
      return '${(value / 1000).toStringAsFixed(2)} s';
    }
    if (isFps) {
      return '${value.toStringAsFixed(2)} FPS';
    }
    return value.toStringAsFixed(2);
  }
}
