import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:buffered_list_stream/buffered_list_stream.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:logging/logging.dart';
import 'package:record/record.dart';
import 'package:vosk_flutter/vosk_flutter.dart';

import 'bluetooth.dart';
import 'display_helper.dart';

void main() => runApp(const MainApp());

/// basic State Machine for the app; mostly for bluetooth lifecycle,
/// all app activity expected to take place during "running" state
enum ApplicationState {
  disconnected,
  scanning,
  connecting,
  ready,
  running,
  stopping,
  disconnecting,
}

final _log = Logger("MainApp");

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  MainAppState createState() => MainAppState();
}

class MainAppState extends State<MainApp> {
  late ApplicationState _currentState;

  // Use BrilliantBluetooth for communications with Frame
  BrilliantDevice? _connectedDevice;
  StreamSubscription? _scanStream;
  StreamSubscription<BrilliantDevice>? _deviceStateSubs;

  MainAppState() {
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen((record) {
      debugPrint('${record.level.name}: ${record.time}: ${record.message}');
    });
    _currentState = ApplicationState.disconnected;
  }

  Future<void> _scanForFrame() async {
    _currentState = ApplicationState.scanning;
    if (mounted) setState(() {});

    await BrilliantBluetooth.requestPermission();

    await _scanStream?.cancel();
    _scanStream = BrilliantBluetooth.scan()
      .timeout(const Duration(seconds: 5), onTimeout: (sink) {
        // Scan timeouts can occur without having found a Frame, but also
        // after the Frame is found and being connected to, even though
        // the first step after finding the Frame is to stop the scan.
        // In those cases we don't want to change the application state back
        // to disconnected
        switch (_currentState) {
          case ApplicationState.scanning:
            _log.fine('Scan timed out after 5 seconds');
            _currentState = ApplicationState.disconnected;
            if (mounted) setState(() {});
            break;
          case ApplicationState.connecting:
            // found a device and started connecting, just let it play out
            break;
          case ApplicationState.ready:
          case ApplicationState.running:
            // already connected, nothing to do
            break;
          default:
            _log.fine('Unexpected state on scan timeout: $_currentState');
            if (mounted) setState(() {});
        }
      })
      .listen((device) {
        _log.fine('Frame found, connecting');
        _currentState = ApplicationState.connecting;
        if (mounted) setState(() {});

        _connectToScannedFrame(device);
      });
  }

  Future<void> _connectToScannedFrame(BrilliantScannedDevice device) async {
    try {
      _log.fine('connecting to scanned device: $device');
      _connectedDevice = await BrilliantBluetooth.connect(device);
      _log.fine('device connected: ${_connectedDevice!.device.remoteId}');

      // subscribe to connection state for the device to detect disconnections
      // so we can transition the app to a disconnected state
      await _deviceStateSubs?.cancel();
      _deviceStateSubs = _connectedDevice!.connectionState.listen((bd) {
        _log.fine('Frame connection state change: ${bd.state.name}');
        if (bd.state == BrilliantConnectionState.disconnected) {
          _currentState = ApplicationState.disconnected;
          _log.fine('Frame disconnected: currentState: $_currentState');
          if (mounted) setState(() {});
        }
      });

      try {
        // terminate the main.lua (if currently running) so we can run our lua code
        // TODO looks like if the signal comes too early after connection, it isn't registered
        await Future.delayed(const Duration(milliseconds: 500));
        await _connectedDevice!.sendBreakSignal();

        // Application is ready to go!
        _currentState = ApplicationState.ready;
        if (mounted) setState(() {});

      } catch (e) {
        _currentState = ApplicationState.disconnected;
        _log.fine('Error while sending break signal: $e');
        if (mounted) setState(() {});

        _disconnectFrame();
      }
    } catch (e) {
      _currentState = ApplicationState.disconnected;
      _log.fine('Error while connecting and/or discovering services: $e');
    }
  }

  Future<void> _reconnectFrame() async {
    if (_connectedDevice != null) {
      try {
        _log.fine('connecting to existing device: $_connectedDevice');
        await BrilliantBluetooth.reconnect(_connectedDevice!.uuid);
        _log.fine('device connected: $_connectedDevice');

        // subscribe to connection state for the device to detect disconnections
        // and transition the app to a disconnected state
        await _deviceStateSubs?.cancel();
        _deviceStateSubs = _connectedDevice!.connectionState.listen((bd) {
          _log.fine('Frame connection state change: ${bd.state.name}');
          if (bd.state == BrilliantConnectionState.disconnected) {
            _currentState = ApplicationState.disconnected;
            _log.fine('Frame disconnected');
            if (mounted) setState(() {});
          }
        });

        try {
          // terminate the main.lua (if currently running) so we can run our lua code
          // TODO looks like if the signal comes too early after connection, it isn't registered
          await Future.delayed(const Duration(milliseconds: 500));
          await _connectedDevice!.sendBreakSignal();

          // Application is ready to go!
          _currentState = ApplicationState.ready;
          if (mounted) setState(() {});

        } catch (e) {
          _currentState = ApplicationState.disconnected;
          _log.fine('Error while sending break signal: $e');
          if (mounted) setState(() {});

        _disconnectFrame();
        }
      } catch (e) {
        _currentState = ApplicationState.disconnected;
        _log.fine('Error while connecting and/or discovering services: $e');
        if (mounted) setState(() {});
      }
    }
    else {
      _currentState = ApplicationState.disconnected;
      _log.fine('Current device is null, reconnection not possible');
      if (mounted) setState(() {});
    }
  }

  Future<void> _disconnectFrame() async {
    _currentState = ApplicationState.disconnecting;
    if (mounted) setState(() {});

    if (_connectedDevice != null) {
      try {
        _log.fine('Disconnecting from Frame');
        // break first in case it's sleeping - otherwise the reset won't work
        await _connectedDevice!.sendBreakSignal();
        _log.fine('Break signal sent');
        // TODO the break signal needs some more time to be processed before we can reliably send the reset signal, by the looks of it
        await Future.delayed(const Duration(milliseconds: 500));

        // try to reset device back to running main.lua
        await _connectedDevice!.sendResetSignal();
        _log.fine('Reset signal sent');
        // TODO the reset signal doesn't seem to be processed in time if we disconnect immediately, so we introduce a delay here to give it more time
        // The sdk's sendResetSignal actually already adds 100ms delay
        // perhaps it's not quite enough.
        await Future.delayed(const Duration(milliseconds: 500));

      } catch (e) {
          _log.fine('Error while sending reset signal: $e');
      }

      try{
          // try to disconnect cleanly if the device allows
          await _connectedDevice!.disconnect();
      } catch (e) {
          _log.fine('Error while calling disconnect(): $e');
      }
    }
    else {
      _log.fine('Current device is null, disconnection not possible');
    }

    _currentState = ApplicationState.disconnected;
    if (mounted) setState(() {});
  }

  /// translate application members
  static const _modelName = 'vosk-model-small-cn-0.22.zip';
  static const _sampleRate = 8000;

  final _vosk = VoskFlutterPlugin.instance();
  final _recorder = AudioRecorder();
  Stream<List<int>>? _audioSampleBufferedStream;

  Model? _model;
  Recognizer? _recognizer;
  String _text = "N/A";
  String _translatedText = "N/A";

  final _translator = OnDeviceTranslator(
    sourceLanguage: TranslateLanguage.chinese,
    targetLanguage: TranslateLanguage.english);

  @override
  void initState() {
    super.initState();
    _initVosk();
  }

  @override
  void dispose() async {
    await _recorder.cancel();
    _recorder.dispose();
    _model?.dispose();
    _recognizer?.dispose();
    _translator.close();
    super.dispose();
  }

  void _initVosk() async {
    final enSmallModelPath = await ModelLoader().loadFromAssets('assets/$_modelName');
    final model = await _vosk.createModel(enSmallModelPath);
    _recognizer = await _vosk.createRecognizer(model: model, sampleRate: _sampleRate);
    setState(() => _model = model);
  }

  Future<bool> _startAudio() async {
    // Check and request permission if needed
    if (await _recorder.hasPermission()) {
      // start the audio stream
      final recordStream = await _recorder.startStream(
        const RecordConfig(encoder: AudioEncoder.pcm16bits,
          numChannels: 1,
          sampleRate: _sampleRate));

      // buffer the audio stream into chunks of 2048 samples
      _audioSampleBufferedStream = bufferedListStream(
        recordStream.map((event) {
          return event.toList();
        }),
        // samples are PCM16, so 2 bytes per sample
        4096 * 2,
      );

      return true;
    }
    return false;
  }

  void _stopAudio() async {
    await _recorder.cancel();
  }

  /// This application uses vosk speech-to-text to listen to audio from the host mic, convert to text,
  /// and send the text to the Frame in real-time
  Future<void> _runApplication() async {
    _currentState = ApplicationState.running;
    if (mounted) setState(() {});

    try {
      if (await _startAudio()) {

        // loop over the incoming audio data and send reults to Frame
        await for (var audioSample in _audioSampleBufferedStream!) {
          if (_recognizer != null) {
            // if the user has clicked Stop we want to stop processing
            // and clear the display
            if (_currentState != ApplicationState.running) {
              DisplayHelper.clear(_connectedDevice!);
              break;
            }

            final resultReady = await _recognizer!.acceptWaveformBytes(Uint8List.fromList(audioSample));

            // parse the Result or Partial Result out of the JSON
            String text = resultReady ?
              jsonDecode(await _recognizer!.getResult())['text'] :
              jsonDecode(await _recognizer!.getPartialResult())['partial'];

            // leave the last utterance there until some more text comes in rather than blanking it
            if (text.isNotEmpty) {
              var translatedText = await _translator.translateText(text);

              try {
                DisplayHelper.writeText(_connectedDevice!, translatedText);
                // TODO need a delay here too?
                await Future.delayed(const Duration(milliseconds: 100));
                DisplayHelper.show(_connectedDevice!);
              }
              catch (e) {
                _log.fine('Error sending text to Frame: $e');
              }

              setState(() {
                _text = text;
                _translatedText = translatedText;
              });
            }
          }
        }

        _stopAudio();
      }
    } catch (e) {
      _log.fine('Error executing application logic: $e');
    }

    _currentState = ApplicationState.ready;
    if (mounted) setState(() {});
  }

  Future<void> _stopApplication() async {
    _currentState = ApplicationState.stopping;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // work out the states of the footer buttons based on the app state
    List<Widget> pfb = [];

    switch (_currentState) {
      case ApplicationState.disconnected:
        pfb.add(TextButton(onPressed: _connectedDevice != null ? _reconnectFrame : _scanForFrame, child: const Text('Connect Frame')));
        pfb.add(const TextButton(onPressed: null, child: Text('Start Translation')));
        pfb.add(const TextButton(onPressed: null, child: Text('Finish')));
        break;

      case ApplicationState.scanning:
      case ApplicationState.connecting:
      case ApplicationState.disconnecting:
      case ApplicationState.stopping:
        pfb.add(const TextButton(onPressed: null, child: Text('Connect Frame')));
        pfb.add(const TextButton(onPressed: null, child: Text('Start Translation')));
        pfb.add(const TextButton(onPressed: null, child: Text('Finish')));
        break;

      case ApplicationState.ready:
        pfb.add(const TextButton(onPressed: null, child: Text('Connect Frame')));
        pfb.add(TextButton(onPressed: _runApplication, child: const Text('Start Translation')));
        pfb.add(TextButton(onPressed: _disconnectFrame, child: const Text('Finish')));
        break;

      case ApplicationState.running:
        pfb.add(const TextButton(onPressed: null, child: Text('Connect Frame')));
        pfb.add(TextButton(onPressed: _stopApplication, child: const Text('Stop Translation')));
        pfb.add(const TextButton(onPressed: null, child: Text('Finish')));
        break;
    }

    return MaterialApp(
      title: 'Translation (Host)',
      theme: ThemeData.dark(),
      home: Scaffold(
        appBar: AppBar(
          title: const Text("Frame Translation"),
        ),
        body: Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(_text, style: const TextStyle(fontSize: 30)),
                const Divider(),
                Text(_translatedText, style: const TextStyle(fontSize: 30, fontStyle: FontStyle.italic)),
              ],
            ),
          ),
        ),
        persistentFooterButtons: pfb,
      ),
    );
  }
}
