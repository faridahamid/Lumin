import 'package:flutter/material.dart';

import '../services/performance_metrics.dart';

class MetricsScreen extends StatefulWidget {
  const MetricsScreen({super.key});

  @override
  State<MetricsScreen> createState() => _MetricsScreenState();
}

class _MetricsScreenState extends State<MetricsScreen> {
  late Future<List<MetricSummary>> _future;

  @override
  void initState() {
    super.initState();
    _future = PerformanceMetrics.summaries();
  }

  void _refresh() {
    setState(() {
      _future = PerformanceMetrics.summaries();
    });
  }

  Future<void> _reset() async {
    await PerformanceMetrics.reset();
    if (mounted) {
      _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF07111F),
      appBar: AppBar(
        title: const Text('Performance Metrics'),
        backgroundColor: Colors.black,
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
          IconButton(
            tooltip: 'Reset',
            icon: const Icon(Icons.delete_outline),
            onPressed: _reset,
          ),
        ],
      ),
      body: FutureBuilder<List<MetricSummary>>(
        future: _future,
        builder: (context, snapshot) {
          final metrics = snapshot.data ?? const <MetricSummary>[];
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (metrics.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No samples yet. Reset before testing, use the app features, then come back here.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white, fontSize: 18),
                ),
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: metrics.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              return _MetricCard(summary: metrics[index]);
            },
          );
        },
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.summary});

  final MetricSummary summary;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF10243A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              summary.title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            _MetricRow(label: 'Average', value: summary.format(summary.average)),
            _MetricRow(label: 'Minimum', value: summary.format(summary.minimum)),
            _MetricRow(label: 'Maximum', value: summary.format(summary.maximum)),
            _MetricRow(label: 'Samples', value: summary.count.toString()),
          ],
        ),
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 15),
            ),
          ),
          Text(
            value,
            style: const TextStyle(color: Colors.white, fontSize: 15),
          ),
        ],
      ),
    );
  }
}
