import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

final _log = Logger("Bluetooth");

class BrilliantBluetoothException implements Exception {
  final String msg;
  const BrilliantBluetoothException(this.msg);
  @override
  String toString() => 'BrilliantBluetoothException: $msg';
}

enum BrilliantConnectionState {
  connected,
  disconnected,
}

class BrilliantScannedDevice {
  BluetoothDevice device;
  int? rssi;

  BrilliantScannedDevice({
    required this.device,
    required this.rssi,
  });
}

class BrilliantDevice {
  BluetoothDevice device;
  BrilliantConnectionState state;
  int? maxStringLength;
  int? maxDataLength;

  BluetoothCharacteristic? _txChannel;
  BluetoothCharacteristic? _rxChannel;

  BrilliantDevice({
    required this.state,
    required this.device,
    this.maxStringLength,
    this.maxDataLength,
  });

  // to enable reconnect()
  String get uuid => device.remoteId.str;

  Stream<BrilliantDevice> get connectionState {
    return FlutterBluePlus.events.onConnectionStateChanged
        .where((event) =>
            event.connectionState == BluetoothConnectionState.connected ||
            (event.connectionState == BluetoothConnectionState.disconnected &&
                event.device.disconnectReason != null &&
                event.device.disconnectReason!.code != 23789258))
        .asyncMap((event) async {
      if (event.connectionState == BluetoothConnectionState.connected) {
        _log.info("Connection state stream: Connected");
        try {
          return await BrilliantBluetooth._enableServices(event.device);
        } catch (error) {
          _log.warning("Connection state stream: Invalid due to $error");
          return Future.error(BrilliantBluetoothException(error.toString()));
        }
      }
      _log.info(
          "Connection state stream: Disconnected due to ${event.device.disconnectReason!.description}");
      // Note: automatic reconnection isn't suitable for all cases, so it might
      // be better to leave this up to the sdk user to specify. iOS appears to
      // use FBP's native autoconnect, so if Android behaviour would change then
      // iOS probably should as well
      // if (Platform.isAndroid) {
      //   event.device.connect(timeout: const Duration(days: 365));
      // }
      return BrilliantDevice(
        state: BrilliantConnectionState.disconnected,
        device: event.device,
      );
    });
  }

  Stream<String> get stringResponse {
    return FlutterBluePlus.events.onCharacteristicReceived
        .where((event) => event.value[0] != 0x01)
        .map((event) {
      if (event.value[0] != 0x02) {
        _log.info("Received string: ${utf8.decode(event.value)}");
      }
      return utf8.decode(event.value);
    });
  }

  Stream<List<int>> get dataResponse {
    return FlutterBluePlus.events.onCharacteristicReceived
        .where((event) => event.value[0] == 0x01)
        .map((event) {
      _log.fine("Received data: ${event.value.sublist(1)}");
      return event.value.sublist(1);
    });
  }

  Future<void> disconnect() async {
    _log.info("Disconnecting");
    try {
      await device.disconnect();
    } catch (_) {}
  }

  Future<void> sendBreakSignal() async {
    _log.info("Sending break signal");
    await sendString("\x03", awaitResponse: false, log: false);
    await Future.delayed(const Duration(milliseconds: 100));
  }

  Future<void> sendResetSignal() async {
    _log.info("Sending reset signal");
    await sendString("\x04", awaitResponse: false, log: false);
    await Future.delayed(const Duration(milliseconds: 100));
  }

  Future<String?> sendString(
    String string, {
    bool awaitResponse = true,
    bool log = true,
  }) async {
    try {
      if (log) {
        _log.info("Sending string: $string");
      }

      if (state != BrilliantConnectionState.connected) {
        throw ("Device is not connected");
      }

      if (string.length > maxStringLength!) {
        throw ("Payload exceeds allowed length of $maxStringLength");
      }

      await _txChannel!.write(utf8.encode(string), withoutResponse: true);

      if (awaitResponse == false) {
        return null;
      }

      final response = await _rxChannel!.onValueReceived
          .timeout(const Duration(seconds: 1))
          .first;

      return utf8.decode(response);
    } catch (error) {
      _log.warning("Couldn't send string. $error");
      return Future.error(BrilliantBluetoothException(error.toString()));
    }
  }

  Future<void> sendData(List<int> data) async {
    try {
      _log.info("Sending ${data.length} bytes of plain data");
      _log.fine(data);

      if (state != BrilliantConnectionState.connected) {
        throw ("Device is not connected");
      }

      if (data.length > maxDataLength!) {
        throw ("Payload exceeds allowed length of $maxDataLength");
      }

      var finalData = data.toList()..insert(0, 0x01);

      await _txChannel!.write(finalData, withoutResponse: true);
    } catch (error) {
      _log.warning("Couldn't send data. $error");
      return Future.error(BrilliantBluetoothException(error.toString()));
    }
  }

  Future<void> uploadScript(String fileName, String filePath) async {
    try {
      _log.info("Uploading script: $fileName");

      String file = await rootBundle.loadString(filePath);

      file = file.replaceAll('\\', '\\\\');
      file = file.replaceAll("\n", "\\n");
      file = file.replaceAll("'", "\\'");
      file = file.replaceAll('"', '\\"');

      var resp = await sendString(
          "f=frame.file.open('$fileName', 'w');print('\x02')",
          log: false);

      if (resp != "\x02") {
        throw ("Error opening file: $resp");
      }

      int index = 0;
      int chunkSize = maxStringLength! - 22;

      while (index < file.length) {
        // Don't go over the end of the string
        if (index + chunkSize > file.length) {
          chunkSize = file.length - index;
        }

        // Don't split on an escape character
        if (file[index + chunkSize - 1] == '\\') {
          chunkSize -= 1;
        }

        String chunk = file.substring(index, index + chunkSize);

        resp = await sendString("f:write('$chunk');print('\x02')", log: false);

        if (resp != "\x02") {
          throw ("Error writing file: $resp");
        }

        index += chunkSize;
      }

      resp = await sendString("f:close();print('\x02')", log: false);

      if (resp != "\x02") {
        throw ("Error closing file: $resp");
      }
    } catch (error) {
      _log.warning("Couldn't upload script. $error");
      return Future.error(BrilliantBluetoothException(error.toString()));
    }
  }
}

class BrilliantBluetooth {
  static Future<void> requestPermission() async {
    try {
      await FlutterBluePlus.startScan();
      await FlutterBluePlus.stopScan();
    } catch (error) {
      _log.warning("Couldn't obtain Bluetooth permission. $error");
      return Future.error(BrilliantBluetoothException(error.toString()));
    }
  }

  static Stream<BrilliantScannedDevice> scan() async* {
    try {
      _log.info("Starting to scan for devices");

      await FlutterBluePlus.startScan(
        withServices: [
          Guid('7a230001-5475-a6a4-654c-8431f6ad49c4'),
          Guid('fe59'),
        ],
        // note: adding a shorter scan period to reflect
        // that it might be used for a short period at the
        // beginning of an app but not running in the background
        timeout: const Duration(seconds: 10),
        continuousUpdates: false,
        removeIfGone: null,
      );
    } catch (error) {
      _log.warning("Scanning failed. $error");
      throw BrilliantBluetoothException(error.toString());
    }

    yield* FlutterBluePlus.scanResults
        .where((results) => results.isNotEmpty)
        // TODO filter by name: "Frame"
        .map((results) {
      ScanResult nearestDevice = results[0];
      for (int i = 0; i < results.length; i++) {
        if (results[i].rssi > nearestDevice.rssi) {
          nearestDevice = results[i];
        }
      }

      _log.fine(
          "Found ${nearestDevice.device.advName} rssi: ${nearestDevice.rssi}");

      return BrilliantScannedDevice(
        device: nearestDevice.device,
        rssi: nearestDevice.rssi,
      );
    });
  }

  static Future<void> stopScan() async {
    try {
      _log.info("Stopping scan for devices");
      await FlutterBluePlus.stopScan();
    } catch (error) {
      _log.warning("Couldn't stop scanning. $error");
      return Future.error(BrilliantBluetoothException(error.toString()));
    }
  }

  static Future<BrilliantDevice> connect(BrilliantScannedDevice scanned) async {
    try {
      _log.info("Connecting");

      await FlutterBluePlus.stopScan();

      await scanned.device.connect(
        autoConnect: Platform.isIOS ? true : false,
        mtu: null,
      );

      final connectionState = await scanned.device.connectionState
          .firstWhere((event) => event == BluetoothConnectionState.connected)
          .timeout(const Duration(seconds: 3));

      if (connectionState == BluetoothConnectionState.connected) {
        return await _enableServices(scanned.device);
      }

      throw ("${scanned.device.disconnectReason?.description}");
    } catch (error) {
      await scanned.device.disconnect();
      _log.warning("Couldn't connect. $error");
      return Future.error(BrilliantBluetoothException(error.toString()));
    }
  }

  static Future<BrilliantDevice> reconnect(String uuid) async {
    try {
      _log.info("Will re-connect to device: $uuid once found");

      BluetoothDevice device = BluetoothDevice.fromId(uuid);

      await device.connect(
        // note: changed so that sdk users (apps) directly specify reconnect behaviour
        // otherwise there are spurious reconnects even after programmatically disconnecting
        timeout: const Duration(seconds: 5),
        autoConnect: false,
        mtu: null,
      );

      final connectionState = await device.connectionState.firstWhere((state) =>
          state == BluetoothConnectionState.connected ||
          (state == BluetoothConnectionState.disconnected &&
              device.disconnectReason != null));

      _log.info("Found reconnectable device: $uuid");

      if (connectionState == BluetoothConnectionState.connected) {
        return await _enableServices(device);
      }

      throw ("${device.disconnectReason?.description}");
    } catch (error) {
      _log.warning("Couldn't reconnect. $error");
      return Future.error(BrilliantBluetoothException(error.toString()));
    }
  }

  static Future<BrilliantDevice> _enableServices(BluetoothDevice device) async {
    if (Platform.isAndroid) {
      await device.requestMtu(512);
    }

    BrilliantDevice finalDevice = BrilliantDevice(
      device: device,
      state: BrilliantConnectionState.disconnected,
    );

    List<BluetoothService> services = await device.discoverServices();

    for (var service in services) {
      // If Frame
      if (service.serviceUuid == Guid('7a230001-5475-a6a4-654c-8431f6ad49c4')) {
        _log.fine("Found Frame service");
        for (var characteristic in service.characteristics) {
          if (characteristic.characteristicUuid ==
              Guid('7a230002-5475-a6a4-654c-8431f6ad49c4')) {
            _log.fine("Found Frame TX characteristic");
            finalDevice._txChannel = characteristic;
          }
          if (characteristic.characteristicUuid ==
              Guid('7a230003-5475-a6a4-654c-8431f6ad49c4')) {
            _log.fine("Found Frame RX characteristic");
            finalDevice._rxChannel = characteristic;

            await characteristic.setNotifyValue(true);
            _log.fine("Enabled RX notifications");

            finalDevice.maxStringLength = device.mtuNow - 3;
            finalDevice.maxDataLength = device.mtuNow - 4;
            _log.fine("Max string length: ${finalDevice.maxStringLength}");
            _log.fine("Max data length: ${finalDevice.maxDataLength}");
          }
        }
      }
    }

    if (finalDevice._txChannel != null && finalDevice._rxChannel != null) {
      finalDevice.state = BrilliantConnectionState.connected;
      return finalDevice;
    }

    throw ("Incomplete set of services found");
  }
}