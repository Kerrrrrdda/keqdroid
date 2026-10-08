import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../core/app_logger.dart';
import 'linux_appimage_updater.dart';
import 'linux_desktop_entry.dart';

/// Автозапуск на Linux: ярлык в `~/.config/autostart` по спецификации XDG
/// Autostart.
///
/// Его исполняют GNOME, KDE, XFCE, Cinnamon, MATE и LXQt. Hyprland и Sway сами
/// автозагрузку XDG не читают — там это делают uwsm или dex, если они стоят.
/// Флаг [flag] отличает запуск при входе от обычного: по нему приложение
/// подключается само, если так настроено.
class LinuxAutostart {
  LinuxAutostart._();

  static const flag = '--autostart';
  static const _fileName = 'keqdroid.desktop';

  /// Метка нашего ярлыка: чужой файл с тем же именем не трогаем.
  static const _marker = 'X-KeqDroid-Autostart=true';

  static File _file() {
    final home = Platform.environment['HOME'] ?? '';
    final config =
        Platform.environment['XDG_CONFIG_HOME'] ?? p.join(home, '.config');
    return File(p.join(config, 'autostart', _fileName));
  }

  /// Что запускать: сам AppImage, а не бинарь в его временном монте —
  /// тот исчезает вместе с процессом.
  static String _target() =>
      LinuxAppImageUpdater.currentAppImagePath() ?? Platform.resolvedExecutable;

  static bool isEnabled() {
    try {
      final file = _file();
      return file.existsSync() && file.readAsStringSync().contains(_marker);
    } catch (_) {
      return false;
    }
  }

  /// true — система делает то, что просили.
  static Future<bool> setEnabled(bool enabled) async {
    try {
      final file = _file();
      if (!enabled) {
        if (isEnabled()) await file.delete();
        return true;
      }
      if (file.existsSync() && !isEnabled()) return false;
      await file.parent.create(recursive: true);
      await file.writeAsString(contentFor(_target()));
      return true;
    } catch (e, st) {
      AppLogger.instance.warn(
        'Could not change Linux autostart',
        error: e,
        stackTrace: st,
      );
      return false;
    }
  }

  /// На старте: путь в ярлыке догоняет переезд AppImage или переустановку.
  static Future<void> refresh() async {
    if (!isEnabled()) return;
    final content = contentFor(_target());
    try {
      if (await _file().readAsString() != content) {
        await _file().writeAsString(content);
      }
    } catch (_) {}
  }

  /// Запущены ли мы ярлыком автозапуска. Аргументы — из `/proc/self/cmdline`:
  /// раннер их в Dart не передаёт, а AppRun AppImage пробрасывает как есть.
  static bool launchedAtLogin() {
    try {
      final raw = File('/proc/self/cmdline').readAsStringSync();
      return raw.split('\u0000').contains(flag);
    } catch (_) {
      return false;
    }
  }

  @visibleForTesting
  static String contentFor(String target) => [
        '[Desktop Entry]',
        'Type=Application',
        'Name=KeqDroid',
        'Exec=${LinuxDesktopEntry.execArgument(target)} $flag',
        'Icon=keqdroid',
        'Terminal=false',
        'X-GNOME-Autostart-enabled=true',
        _marker,
        '',
      ].join('\n');
}
