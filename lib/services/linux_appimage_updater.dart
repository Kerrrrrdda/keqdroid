import 'dart:io';

import 'linux_install.dart';

/// In-place update for the Linux AppImage build.
///
/// Only meaningful when the app is *running as an AppImage*: the AppImage
/// runtime exports `APPIMAGE` = absolute path of the `.AppImage` the user
/// launched. We overwrite that file with the freshly downloaded (and already
/// SHA-256-verified by [UpdateService]) one and relaunch. deb, rpm and tar.gz
/// installs have no `APPIMAGE` and update their own way (see [LinuxInstall]).
class LinuxAppImageUpdater {
  LinuxAppImageUpdater._();

  /// Absolute path of the currently running AppImage, or `null` when the app
  /// was not launched as one (dev build, extracted tree, deb install).
  static String? currentAppImagePath() {
    final path = Platform.environment['APPIMAGE'];
    if (path == null || path.isEmpty) return null;
    return File(path).existsSync() ? path : null;
  }

  /// Replaces the running AppImage [targetAppImage] with [newAppImage] and
  /// relaunches it after this process exits. Returns `true` — the app is
  /// exiting to apply the update (mirrors [WindowsZipUpdater]'s contract).
  static Future<bool> applyInPlace({
    required String newAppImage,
    required String targetAppImage,
    Future<void> Function()? beforeRestart,
  }) async {
    if (!Platform.isLinux) {
      throw StateError('LinuxAppImageUpdater is Linux-only');
    }
    if (!await File(newAppImage).exists()) {
      throw StateError('Downloaded AppImage not found');
    }

    await launchAfterExit(_script, [newAppImage, targetAppImage]);

    await beforeRestart?.call();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    exit(0);
  }

  // Atomically replaces the AppImage with the downloaded one (same-dir `mv`,
  // `cp` fallback), keeps the exec bit, and relaunches.
  static const _script = r'''
NEW="$1"; TARGET="$2"
log "=== appimage update: new=$NEW target=$TARGET"

chmod +x "$NEW" 2>/dev/null
if ! mv -f "$NEW" "$TARGET" 2>>"$LOG"; then
  cp -f "$NEW" "$TARGET" 2>>"$LOG" || log "replace FAILED"
  rm -f "$NEW" 2>/dev/null
fi
chmod +x "$TARGET" 2>/dev/null
log "replaced, relaunching $TARGET"

setsid "$TARGET" >/dev/null 2>&1 < /dev/null &
log "done"
''';
}
