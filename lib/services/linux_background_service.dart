import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect, Size;

import 'package:flutter/foundation.dart' show ValueNotifier, visibleForTesting;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/app_logger.dart';
import 'linux_desktop_entry.dart';
import 'storage_service.dart';

/// Фон и трей на Linux; у Windows трей свой, нативный.
///
/// Крестик не выходит из приложения — туннель продолжает работать. Окно уходит
/// в трей, а когда трея нет (чистый GNOME, тайлинги без модуля трея), — в
/// панель задач: спрятанное окно без значка вернуть было бы нечем. Выход — из
/// меню трея или по Ctrl+Q. AppIndicator умеет только меню, одиночные клики до
/// приложения не доходят вовсе. Второй запуск не плодит копию, а поднимает уже
/// работающее окно.
class LinuxBackgroundService with WindowListener, TrayListener {
  LinuxBackgroundService._();
  static final LinuxBackgroundService instance = LinuxBackgroundService._();

  @visibleForTesting
  LinuxBackgroundService.forTesting();

  /// Под этим id значок живёт между запусками: по нему KDE помнит, показывать
  /// ли его всегда.
  static const _trayId = 'keqdroid';

  /// Сколько дать движку дорисовать последний кадр спрятанного окна.
  @visibleForTesting
  static Duration quitSettleDelay = const Duration(milliseconds: 300);

  /// Выход уже идёт: окно закрываем мы сами, и его событие закрытия — не
  /// просьба человека убрать окно в фон.
  bool _quitting = false;

  /// Видно ли окно человеку — по нашим же действиям. Свёрнутое окно на
  /// Wayland GTK3 видимым и остаётся: композитор не сообщает о сворачивании,
  /// и Flutter рисовал бы волну в фоне. Экран гасит по этому флагу анимации и
  /// опрос трафика, как на Windows (desktopWindowVisibleProvider).
  final ValueNotifier<bool> uiVisible = ValueNotifier(true);

  /// `XDG_CURRENT_DESKTOP` для тестов.
  @visibleForTesting
  static String? desktopOverride;

  /// Подписи меню трея. До первого кадра языка ещё нет, поэтому английские;
  /// экран подменяет их на язык интерфейса ([setTrayLabels]).
  String _showLabel = 'Show keqdroid';
  String _quitLabel = 'Quit';

  // Loopback "lock": only one process can bind it; later launches connect to it.
  static const int _lockPort = 47351;

  ServerSocket? _lock;

  /// Set by the UI so "Quit" can tear the tunnel down before exiting.
  Future<void> Function()? onQuit;

  /// Binds the single-instance lock. Returns `false` when another instance
  /// already holds it (after asking that instance to show its window) — the
  /// caller should then `exit(0)`.
  Future<bool> ensureSingleInstance() async {
    try {
      _lock = await ServerSocket.bind('127.0.0.1', _lockPort, shared: false);
      _lock!.listen((socket) {
        socket.destroy(); // any ping means "another launch happened" -> show
        unawaitedShow();
      });
      return true;
    } on SocketException {
      try {
        final s = await Socket.connect(
          '127.0.0.1',
          _lockPort,
          timeout: const Duration(seconds: 2),
        );
        s.add('show'.codeUnits);
        await s.flush();
        s.destroy();
      } catch (_) {
        // running instance not answering; fall through and let caller exit
      }
      return false;
    }
  }

  Future<void> initWindowAndTray() async {
    // Ярлык AppImage даёт окну иконку на Wayland, см. LinuxDesktopEntry.
    unawaited(LinuxDesktopEntry.sync());
    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);
    await _restoreWindowBounds();

    trayManager.addListener(this);
    try {
      await trayManager.setIcon('assets/icon.png', id: _trayId, title: 'keqdroid');
      // Нет setToolTip: Linux-реализация tray_manager его не поддерживает
      // (MissingPluginException), а вылет здесь оставит индикатор с пустым
      // меню — AppIndicator без меню вообще не реагирует на клики.
      await _applyTrayMenu();
    } catch (e, st) {
      // No StatusNotifier/AppIndicator host (e.g. vanilla GNOME): the app still
      // runs in the background; single-instance relaunch restores the window.
      AppLogger.instance.warn(
        'Tray init failed (no AppIndicator host?). Background mode still works; '
        'relaunch the app to restore the window.',
        error: e,
        stackTrace: st,
      );
    }
  }

  Future<void> _applyTrayMenu() => trayManager.setContextMenu(
        Menu(items: [
          MenuItem(key: 'show', label: _showLabel),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: _quitLabel),
        ]),
      );

  /// Меню трея на языке интерфейса; зовёт экран, когда язык известен или сменился.
  Future<void> setTrayLabels({
    required String show,
    required String quit,
  }) async {
    if (show == _showLabel && quit == _quitLabel) return;
    _showLabel = show;
    _quitLabel = quit;
    try {
      await _applyTrayMenu();
    } catch (_) {
      // Трея нет — меню показывать некому.
    }
  }

  void unawaitedShow() {
    _showWindow();
  }

  /// Хоткей «показать/скрыть окно»: видимое окно уходит в фон, скрытое или
  /// свёрнутое — возвращается.
  Future<void> toggleWindowVisibility() async {
    if (await windowManager.isVisible() && !await windowManager.isMinimized()) {
      _boundsSaveDebounce?.cancel();
      await _saveWindowBounds();
      await _sendToBackground();
    } else {
      await _showWindow();
    }
  }

  /// В трей, если он есть, иначе в панель задач. Тайлинговые композиторы окна
  /// не сворачивают вовсе — просьба молча пропадает, и крестик выглядел бы
  /// сломанным; там окно прячется, а возвращает его повторный запуск.
  Future<void> _sendToBackground() async {
    uiVisible.value = false;
    if (await _trayAvailable() || isTilingDesktop(desktopOverride)) {
      await windowManager.hide();
    } else {
      await windowManager.minimize();
    }
  }

  static const _tilingDesktops = {'hyprland', 'sway', 'niri', 'river'};

  /// Тот же список, что у шапки окна в linux/runner/my_application.cc.
  static bool isTilingDesktop([String? desktop]) =>
      (desktop ?? Platform.environment['XDG_CURRENT_DESKTOP'] ?? '')
          .toLowerCase()
          .split(':')
          .any(_tilingDesktops.contains);

  /// Спрашивается в момент закрытия, а не на старте: панель с треем часто
  /// поднимается позже приложений из автозапуска.
  Future<bool> _trayAvailable() async {
    try {
      return await trayManager.isAvailable();
    } catch (_) {
      return true; // неизвестно — ведём себя как раньше
    }
  }

  Future<void> _showWindow() async {
    uiVisible.value = true;
    await windowManager.show();
    await windowManager.focus();
  }

  // ---- Window bounds persistence -------------------------------------------
  //
  // GTK шлёт resize/move событиями непрерывно, поэтому запись дебаунсится.
  // Под Wayland позиция окна недоступна приложению — восстанавливается хотя бы
  // размер; на X11 работает и позиция.

  Timer? _boundsSaveDebounce;

  Future<void> _restoreWindowBounds() async {
    try {
      final storage = await StorageService.init();
      final raw = storage.getWindowBoundsJson();
      if (raw == null) return;
      final data = jsonDecode(raw);
      if (data is! Map) return;
      final w = (data['w'] as num?)?.toDouble();
      final h = (data['h'] as num?)?.toDouble();
      final x = (data['x'] as num?)?.toDouble();
      final y = (data['y'] as num?)?.toDouble();
      final maximized = data['maximized'] as bool? ?? false;
      if (w == null || h == null || w < 480 || h < 320) return;
      if (x != null && y != null && x > -10000 && y > -10000) {
        await windowManager.setBounds(Rect.fromLTWH(x, y, w, h));
      } else {
        await windowManager.setSize(Size(w, h));
      }
      if (maximized) {
        await windowManager.maximize();
      }
    } catch (e, st) {
      AppLogger.instance.warn(
        'Failed to restore window bounds',
        error: e,
        stackTrace: st,
      );
    }
  }

  void _scheduleBoundsSave() {
    _boundsSaveDebounce?.cancel();
    _boundsSaveDebounce =
        Timer(const Duration(milliseconds: 600), () => _saveWindowBounds());
  }

  Future<void> _saveWindowBounds() async {
    try {
      final storage = await StorageService.init();
      final maximized = await windowManager.isMaximized();
      Map<String, dynamic> data;
      if (maximized) {
        // Не затираем последние «нормальные» границы размером во весь экран —
        // после unmaximize окно должно вернуться к ним.
        final raw = storage.getWindowBoundsJson();
        final prev = raw != null ? jsonDecode(raw) : null;
        data = prev is Map
            ? {...prev.map((k, v) => MapEntry(k.toString(), v))}
            : <String, dynamic>{};
        data['maximized'] = true;
      } else {
        final bounds = await windowManager.getBounds();
        data = {
          'x': bounds.left,
          'y': bounds.top,
          'w': bounds.width,
          'h': bounds.height,
          'maximized': false,
        };
      }
      await storage.setWindowBoundsJson(jsonEncode(data));
    } catch (e, st) {
      AppLogger.instance.warn(
        'Failed to save window bounds',
        error: e,
        stackTrace: st,
      );
    }
  }

  // ---- WindowListener -----------------------------------------------------

  @override
  void onWindowClose() {
    if (_quitting) return;
    _boundsSaveDebounce?.cancel();
    _saveWindowBounds();
    unawaited(_sendToBackground());
  }

  /// Свёрнутое окно вернули из панели задач: другого сигнала на Wayland нет.
  @override
  void onWindowFocus() => uiVisible.value = true;

  @override
  void onWindowResize() => _scheduleBoundsSave();

  @override
  void onWindowMove() => _scheduleBoundsSave();

  @override
  void onWindowMaximize() => _scheduleBoundsSave();

  @override
  void onWindowUnmaximize() => _scheduleBoundsSave();

  // ---- TrayListener -------------------------------------------------------
  //
  // Только пункты меню: mouse-down событий и popUpContextMenu у AppIndicator
  // нет, меню показывает сам хост (шелл) по клику на иконку.

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        _showWindow();
      case 'quit':
        quit();
    }
  }

  /// Выход: пункт трея и Ctrl+Q.
  Future<void> quit() async {
    if (_quitting) return;
    _quitting = true;
    try {
      await onQuit?.call();
    } catch (_) {}
    _boundsSaveDebounce?.cancel();
    await _saveWindowBounds();
    try {
      await trayManager.destroy();
    } catch (_) {}
    // Окно, уничтоженное посреди кадра, роняет процесс в движке: мьютекс кадра
    // освобождается, пока его держит растровый поток (abort в g_mutex_clear,
    // 3 выхода из 6 при открытом окне). Спрятанное окно Flutter не рисует,
    // поэтому сначала прячем и даём дорисоваться последнему кадру.
    await windowManager.hide();
    await Future<void>.delayed(quitSettleDelay);
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }
}

