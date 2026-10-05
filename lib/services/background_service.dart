import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../l10n/app_localizations.dart';
import '../utils/platform_info.dart';
import 'background_ble_handler.dart';

class BackgroundService {
  bool _initialized = false;
  String? Function()? _languageOverrideProvider;

  void setLanguageOverrideProvider(String? Function()? provider) {
    _languageOverrideProvider = provider;
  }

  Future<void> initialize() async {
    if (!PlatformInfo.isAndroid || _initialized) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'meshcore_background',
        channelName: 'MeshCore Background',
        channelDescription: 'Keeps MeshCore running in the background.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(5000),
        autoRunOnBoot: false,
        allowWifiLock: false,
      ),
    );
    _initialized = true;
  }

  Future<void> start() async {
    if (!PlatformInfo.isAndroid) return;
    if (!_initialized) {
      await initialize();
    }
    final running = await FlutterForegroundTask.isRunningService;
    if (running) return;
    final l10n = await _loadLocalizations();
    await FlutterForegroundTask.startService(
      notificationTitle: l10n.background_serviceTitle,
      notificationText: l10n.background_serviceText,
      callback: startCallback,
    );
  }

  Future<AppLocalizations> _loadLocalizations() async {
    final supported = AppLocalizations.supportedLocales;
    final override = _languageOverrideProvider?.call();
    if (override != null && override.isNotEmpty) {
      final overrideLocale = Locale(override);
      final isSupported = supported.any(
        (l) => l.languageCode == overrideLocale.languageCode,
      );
      if (isSupported) {
        return AppLocalizations.delegate.load(overrideLocale);
      }
    }
    final preferred = WidgetsBinding.instance.platformDispatcher.locales;
    final match = basicLocaleListResolution(preferred, supported);
    return AppLocalizations.delegate.load(match);
  }

  static Future<void> openBatteryOptimizationSettings() async {
    if (!PlatformInfo.isAndroid) return;
    await FlutterForegroundTask.openIgnoreBatteryOptimizationSettings();
  }

  Future<void> stop() async {
    if (!PlatformInfo.isAndroid) return;
    final running = await FlutterForegroundTask.isRunningService;
    if (!running) return;
    await FlutterForegroundTask.stopService();
  }

  /// Send a command to the service isolate.
  Future<void> sendCommand(Map<String, dynamic> data) async {
    if (!PlatformInfo.isAndroid) return;
    final running = await FlutterForegroundTask.isRunningService;
    if (!running) return;
    FlutterForegroundTask.sendDataToTask(data);
  }
}

@pragma('vm:entry-point')
void startCallback() {
  print('[BackgroundService] startCallback entered'); // <-- add this
  FlutterForegroundTask.setTaskHandler(_MeshCoreTaskHandler());
}

class _MeshCoreTaskHandler extends TaskHandler {
  final BackgroundBleHandler _bleHandler = BackgroundBleHandler();

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    print('[BackgroundService] onStart fired: $starter'); // <-- add this
    try {
      await _bleHandler.start();
      await FlutterForegroundTask.updateService(
        notificationTitle: 'MeshCore',
        notificationText: 'bg up (${starter.name})',
      );
    } catch (e, st) {
      await FlutterForegroundTask.updateService(
        notificationTitle: 'MeshCore',
        notificationText: 'bg error: $e',
      );
      print('[BackgroundBleHandler] onStart failed: $e\n$st');
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    _bleHandler.onTick();
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    await _bleHandler.stop();
  }

  @override
  void onNotificationButtonPressed(String id) {}

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp('/');
  }

  @override
  void onReceiveData(Object data) {
    _bleHandler.onReceiveData(data);
  }
}
