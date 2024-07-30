import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:buffered_list_stream/buffered_list_stream.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
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
  static const _modelName = 'vosk-model-small-pt-0.3.zip';
  static const _sampleRate = 8000;

  final _vosk = VoskFlutterPlugin.instance();
  final _recorder = AudioRecorder();
  late final Stream<List<int>> audioSampleBufferedStream;

  Model? _model;
  Recognizer? _recognizer;
  String _text = "N/A";
  String _translatedText = "N/A";

  final _translator = OnDeviceTranslator(
    sourceLanguage: TranslateLanguage.portuguese,
    targetLanguage: TranslateLanguage.english);

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
    _translator.close();
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

          // parse the Result or Partial Result out of the JSON
          var text = resultReady ?
            jsonDecode(await _recognizer!.getResult())['text'] :
            jsonDecode(await _recognizer!.getPartialResult())['partial'];

          // leave the last utterance there until some more text comes in rather than blanking it
          if (text.toString().isNotEmpty) {
            var translatedText = await _translator.translateText(text);

            setState(() {
              _text = text;
              _translatedText = translatedText;
            });
          }
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_model == null) {
      return const Scaffold(
          body: Center(child: Text("Loading model...")));
    }
    else {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(_text,
                style: const TextStyle(fontSize: 30)),
              const Divider(),
              Text(_translatedText,
                style: const TextStyle(fontSize: 30, fontStyle: FontStyle.italic)),
            ],
          ),
        ),
      );
    }
  }
}
