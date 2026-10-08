import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../services/desktop_background_service.dart';
import '../services/windows_desktop_service.dart';

/// Platform init before runApp (Windows desktop shell).
class PlatformBootstrap {
  static Future<void> initialize() async {
    if (Platform.isWindows) {
      await WindowsDesktopService.initCoreProcessGuard();
      await DesktopBackgroundService.init();
    }
    if (Platform.isAndroid) {
      try {
        _isTelevision = await const MethodChannel('keqdis_vpn_channel')
                .invokeMethod<bool>('isTelevision') ??
            false;
      } on PlatformException {
        _isTelevision = false;
      }
    }
  }

  /// Тесты гоняются на Windows, и без подмены раскладку телефона там не
  /// проверить.
  @visibleForTesting
  static bool? debugIsDesktopOverride;

  static bool get isDesktop =>
      debugIsDesktopOverride ??
      (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  static bool _isTelevision = false;

  @visibleForTesting
  static bool? debugIsTelevisionOverride;

  /// Android TV: управление пультом, камеры нет. Узнаётся один раз до первого
  /// кадра — режим интерфейса у телевизора не меняется.
  static bool get isTelevision => debugIsTelevisionOverride ?? _isTelevision;
}
