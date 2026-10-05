import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../models/message.dart';
import '../connector/meshcore_protocol.dart';
import '../storage/message_store.dart';
import '../storage/prefs_manager.dart';
import 'notification_service.dart';

class BackgroundBleHandler {
  static const String _lastDeviceIdKey = 'background_ble_last_device_id';
  static const String _selfPublicKeyHexKey = 'background_ble_self_pubkey';

  static const String _serviceUuid = "6e400001-b5a3-f393-e0a9-e50e24dcca9e";
  static const String _rxCharacteristicUuid =
      "6e400002-b5a3-f393-e0a9-e50e24dcca9e";
  static const String _txCharacteristicUuid =
      "6e400003-b5a3-f393-e0a9-e50e24dcca9e";

  fbp.BluetoothDevice? _device;
  fbp.BluetoothCharacteristic? _rxCharacteristic;
  fbp.BluetoothCharacteristic? _txCharacteristic;
  StreamSubscription<fbp.BluetoothConnectionState>? _connectionSubscription;
  StreamSubscription<List<int>>? _notifySubscription;
  Timer? _reconnectTimer;
  bool _manualDisconnect = false;
  bool _isConnected = false;
  bool _connectInFlight = false;

  final MessageStore _messageStore = MessageStore();
  final NotificationService _notificationService = NotificationService();

  Future<void> start() async {
    await PrefsManager.initialize(); // fresh engine needs its own init
    await _notificationService.initialize();
    await _loadLastDevice();
    await _connect();
  }

  Future<void> stop() async {
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    await _disconnect();
  }

  /// Called by the task handler's periodic repeat event. Retries the
  /// connection whenever the link is down and no attempt is already running.
  void onTick() {
    if (_isConnected || _manualDisconnect || _connectInFlight) return;
    unawaited(_connect());
  }

  void onReceiveData(Object data) {
    if (data is! Map) return;
    final cmd = data['cmd'] as String?;
    switch (cmd) {
      case 'disconnect':
        _manualDisconnect = true;
        unawaited(_disconnect());
        break;
      case 'set_device':
        final deviceId = data['deviceId'] as String?;
        final selfPubKeyHex = data['selfPubKeyHex'] as String?;
        if (deviceId != null) {
          _saveLastDevice(deviceId, selfPubKeyHex);
        }
        break;
      case 'ui_alive':
        _notifyUi('connection_state', {'connected': _isConnected});
        break;
    }
  }

  Future<void> _loadLastDevice() async {
    final prefs = PrefsManager.instance;
    final selfPubKeyHex = prefs.getString(_selfPublicKeyHexKey);
    if (selfPubKeyHex != null) {
      _messageStore.setPublicKeyHex = selfPubKeyHex;
    }
  }

  Future<void> _saveLastDevice(String deviceId, String? selfPubKeyHex) async {
    final prefs = PrefsManager.instance;
    await prefs.setString(_lastDeviceIdKey, deviceId);
    if (selfPubKeyHex != null) {
      await prefs.setString(_selfPublicKeyHexKey, selfPubKeyHex);
      _messageStore.setPublicKeyHex = selfPubKeyHex;
    }
  }

  Future<void> _connect() async {
    if (_connectInFlight) return;
    _connectInFlight = true;
    try {
      print(
        '[BackgroundBleHandler] _connect: manualDisconnect=$_manualDisconnect',
      );
      if (_manualDisconnect) return;

      final prefs = PrefsManager.instance;
      final deviceId = prefs.getString(_lastDeviceIdKey);
      print('[BackgroundBleHandler] _connect: deviceId=$deviceId');
      if (deviceId == null || deviceId.isEmpty) return;

      // Don't grab the link while the UI engine holds it.
      final heldElsewhere = fbp.FlutterBluePlus.connectedDevices.any(
        (d) => d.remoteId.toString() == deviceId,
      );
      if (heldElsewhere) {
        print('[BackgroundBleHandler] _connect: link held by UI, parking');
        return;
      }

      try {
        final device = fbp.BluetoothDevice.fromId(deviceId);
        _device = device; // stored for _disconnect; use local 'device' below
        print('[BackgroundBleHandler] _connect: connecting directly');
        await device.connect(
          license: fbp.License.nonprofit, // must match the UI's license
          timeout: const Duration(seconds: 15),
          mtu: 185, // requested on connect; no separate requestMtu needed
          autoConnect: false,
        );
        print('[BackgroundBleHandler] _connect: connected, discovering');

        final services = await device.discoverServices();
        for (final service in services) {
          final serviceUuid = service.serviceUuid.toString().toLowerCase();
          if (serviceUuid == _serviceUuid.toLowerCase()) {
            for (final characteristic in service.characteristics) {
              final charUuid = characteristic.characteristicUuid
                  .toString()
                  .toLowerCase();
              if (charUuid == _rxCharacteristicUuid.toLowerCase()) {
                _rxCharacteristic = characteristic;
              } else if (charUuid == _txCharacteristicUuid.toLowerCase()) {
                _txCharacteristic = characteristic;
              }
            }
          }
        }

        if (_rxCharacteristic == null || _txCharacteristic == null) {
          print('[BackgroundBleHandler] _connect: characteristics not found');
          await _disconnect();
          _scheduleReconnect();
          return;
        }

        await _txCharacteristic!.setNotifyValue(true);
        _notifySubscription = _txCharacteristic!.onValueReceived.listen(
          _onDataReceived,
          onError: (Object e) {
            _scheduleReconnect();
          },
        );

        _connectionSubscription = device.connectionState.listen((state) {
          if (state == fbp.BluetoothConnectionState.disconnected) {
            _isConnected = false;
            _notifyUi('connection_state', {'connected': false});
            if (!_manualDisconnect) {
              _scheduleReconnect();
            }
          }
        });

        _isConnected = true;
        _reconnectTimer?.cancel();
        print('[BackgroundBleHandler] _connect: link up');
        _notifyUi('connection_state', {'connected': true});

        _sendFrame(buildAppStartFrame());
      } catch (e, st) {
        print('[BackgroundBleHandler] _connect failed: $e\n$st');
        _scheduleReconnect();
      }
    } finally {
      _connectInFlight = false;
    }
  }

  Future<void> _disconnect() async {
    _isConnected = false;
    await _notifySubscription?.cancel();
    _notifySubscription = null;
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    try {
      await _device?.disconnect();
    } catch (_) {}
    _device = null;
    _rxCharacteristic = null;
    _txCharacteristic = null;
    _notifyUi('connection_state', {'connected': false});
  }

  void _scheduleReconnect() {
    if (_manualDisconnect) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), _connect);
  }

  void _onDataReceived(List<int> data) {
    if (data.isEmpty) return;
    final frame = Uint8List.fromList(data);
    final code = frame[0];

    switch (code) {
      case respCodeContactMsgRecv:
      case respCodeContactMsgRecvV3:
        _handleContactMessage(frame);
        break;
      case respCodeChannelMsgRecv:
      case respCodeChannelMsgRecvV3:
        _handleChannelMessage(frame);
        break;
      case respCodeBattAndStorage:
        _handleBattery(frame);
        break;
      case pushCodeAdvert:
      case pushCodeNewAdvert:
        _handleAdvert(frame);
        break;
    }
  }

  void _handleContactMessage(Uint8List frame) {
    final parsed = parseContactMessageText(frame);
    if (parsed == null) return;

    final contactKeyHex = pubKeyToHex(parsed.senderPrefix);
    final message = Message(
      senderKey: parsed.senderPrefix,
      text: parsed.text,
      timestamp: DateTime.now(),
      isOutgoing: false,
      status: MessageStatus.delivered,
    );

    unawaited(_messageStore.saveMessages(contactKeyHex, [message]));

    _notifyUi('message', {'contactKeyHex': contactKeyHex, 'text': parsed.text});

    unawaited(
      _notificationService.showMessageNotification(
        contactName: contactKeyHex,
        message: parsed.text,
        contactId: contactKeyHex,
        urlImagesEnabled: false,
      ),
    );
  }

  void _handleChannelMessage(Uint8List frame) {
    _notifyUi('channel_message', {'raw': frame});
  }

  void _handleBattery(Uint8List frame) {
    if (frame.length < 3) return;
    final reader = BufferReader(frame);
    reader.skipBytes(1);
    final mv = reader.readUInt16LE();
    _notifyUi('battery', {'millivolts': mv});
  }

  void _handleAdvert(Uint8List frame) {
    _notifyUi('advert', {'raw': frame});
  }

  void _sendFrame(Uint8List frame) {
    if (_rxCharacteristic == null) return;
    unawaited(_rxCharacteristic!.write(frame, withoutResponse: false));
  }

  void _notifyUi(String type, Map<String, dynamic> data) {
    FlutterForegroundTask.sendDataToMain({'type': type, ...data});
  }
}
