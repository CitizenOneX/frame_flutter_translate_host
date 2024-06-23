import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:buffered_list_stream/buffered_list_stream.dart';
import 'package:record/record.dart';
import 'package:vosk_flutter/vosk_flutter.dart';

void main() {
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _textStyle = TextStyle(fontSize: 30, color: Colors.black);
  static const _modelName = 'vosk-model-small-en-us-0.15.zip';
  static const _sampleRate = 16000;

  final _vosk = VoskFlutterPlugin.instance();
  final _recorder = AudioRecorder();
  late final Stream<List<int>> audioSampleBufferedStream;

  Model? _model;
  Recognizer? _recognizer;
  String _partialResult = "N/A";
  String _finalResult = "N/A";

  @override
  void initState() {
    super.initState();

    _initVosk();
    _initAudio();
  }

  @override
  void dispose() async {
    await _recorder.cancel();
    _recorder.dispose();
    super.dispose();
  }

  void _initVosk() async {
    final enSmallModelPath = await ModelLoader().loadFromAssets('assets/$_modelName');
    final model = await _vosk.createModel(enSmallModelPath);
    _recognizer = await _vosk.createRecognizer(model: model, sampleRate: _sampleRate);
    setState(() => _model = model);
  }

  void _initAudio() async {
    // Check and request permission if needed
    if (await _recorder.hasPermission()) {
      // start the audio stream
      final recordStream = await _recorder.startStream(
        const RecordConfig(encoder: AudioEncoder.pcm16bits,
          numChannels: 1,
          sampleRate: _sampleRate));

      // buffer the audio stream into chunks of 2048 samples
      audioSampleBufferedStream = bufferedListStream(
        recordStream.map((event) {
          return event.toList();
        }),
        // samples are PCM16, so 2 bytes per sample
        4096 * 2,
      );

      // loop over the incoming audio data
      await for (var audioSample in audioSampleBufferedStream) {
        if (_recognizer != null) {
          final resultReady = await _recognizer!.acceptWaveformBytes(Uint8List.fromList(audioSample));

          if (resultReady) {
            var result = await _recognizer!.getResult();
            setState(() => _finalResult = result);
          }
          else {
            var result = await _recognizer!.getPartialResult();
            setState(() => _partialResult = result);
          }
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_model == null) {
      return const Scaffold(
          body: Center(child: Text("Loading model...", style: _textStyle)));
    }
    else {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('Partial result: $_partialResult', style: _textStyle),
              Text('Final result: $_finalResult', style: _textStyle),
            ],
          ),
        ),
      );
    }
  }
}
