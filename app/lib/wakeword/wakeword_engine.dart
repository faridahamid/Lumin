import 'dart:io';


import 'package:flutter/material.dart';
import 'package:porcupine_flutter/porcupine_manager.dart';
import 'package:porcupine_flutter/porcupine_error.dart';


enum AppState { initial, loading, ready, listening }


class PorcupineWidget extends StatefulWidget {
  const PorcupineWidget({super.key});


  @override
  State<PorcupineWidget> createState() => _PorcupineWidgetState();
}


class _PorcupineWidgetState extends State<PorcupineWidget> {
  PorcupineManager? _porcupineManager;
  AppState _appState = AppState.initial;


  // Handle detected keywords
  void _detectionCallback(int keywordIndex) {
    if (keywordIndex == 0) {
      print('Keyword detected');
    }
  }


  void _processErrorCallback(PorcupineException err) {
    print('Porcupine error: ${err.message}');
  }


  // 1. Initialize Porcupine
  Future<void> _init() async {
    setState(() => _appState = AppState.loading);


    if (_porcupineManager == null) {
      try {
        var platform = (Platform.isAndroid) ? "android" : "ios";
        var keywordPath =
            "assets/Lumen_en_${platform}_v4_0_0.ppn"; // e.g. "assets/blueberry_$platform.ppn";
        _porcupineManager = await PorcupineManager.fromKeywordPaths(
          "YOUR_PICOVOICE_ACCESS_KEY",
          [keywordPath],
          _detectionCallback,
          errorCallback: _processErrorCallback,
          // modelPath: "assets/{MODEL_FILE}", // (if non-English keyword)
        );


        setState(() => _appState = AppState.ready);
      } on PorcupineException catch (err) {
        print('Porcupine initialization failed: ${err.message}');
        setState(() => _appState = AppState.initial);
      }
    }
  }


  // 2. Start listening for keywords
  Future<void> _start() async {
    if (_porcupineManager == null) return;
    setState(() => _appState = AppState.loading);


    try {
      await _porcupineManager?.start();
      setState(() => _appState = AppState.listening);
    } on PorcupineException catch (err) {
      print('Error starting voice processor: ${err.message}');
      setState(() => _appState = AppState.ready);
    }
  }


  // 3. Stop listening for keywords
  Future<void> _stop() async {
    setState(() => _appState = AppState.loading);


    try {
      await _porcupineManager?.stop();
      setState(() => _appState = AppState.ready);
    } on PorcupineException catch (err) {
      print('Error stopping voice processor: ${err.message}');
      setState(() => _appState = AppState.listening);
    }
  }


  // 4. Clean up resources
  Future<void> _delete() async {
    setState(() => _appState = AppState.loading);


    await _stop();


    await _porcupineManager?.delete();
    _porcupineManager = null;


    setState(() => _appState = AppState.initial);
  }


  @override
  void dispose() {
    _porcupineManager?.delete();
    super.dispose();
  }


  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ElevatedButton(
          onPressed: _appState == AppState.initial ? _init : null,
          child: const Text('Init'),
        ),
        ElevatedButton(
          onPressed: _appState == AppState.ready ? _start : null,
          child: const Text('Start'),
        ),
        ElevatedButton(
          onPressed: _appState == AppState.listening ? _stop : null,
          child: const Text('Stop'),
        ),
        ElevatedButton(
          onPressed: _appState == AppState.ready ? _delete : null,
          child: const Text('Delete'),
        ),
      ],
    );
  }
}
