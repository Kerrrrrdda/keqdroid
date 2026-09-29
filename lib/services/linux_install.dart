import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;

import 'linux_appimage_updater.dart';

/// Как установлена Linux-версия.
///
/// От этого зависит, какой файл релиза качать и кто вправе заменить
/// установленное: AppImage и распакованный архив меняем сами, deb и rpm ставит
/// пакетный менеджер, а пакет pacman (AUR или PKGBUILD из релиза) обновляет
/// только pacman.
enum LinuxInstallKind {
  appImage,
  deb,
  rpm,
  pacman,

  /// Распакованный tar.gz в папке, куда можно писать.
  portable,

  /// Распакованный tar.gz в папке только для чтения: заменить файлы нечем,
  /// остаётся скачать архив браузером.
  readOnly,
}

class LinuxInstall {
  LinuxInstall._();

  static Future<LinuxInstallKind>? _detected;

  /// Способ установки этого процесса; за время жизни он не меняется.
  static Future<LinuxInstallKind> detect() => _detected ??= classify(
        appImagePath: LinuxAppImageUpdater.currentAppImagePath(),
        executable: Platform.resolvedExecutable,
        owns: _owns,
        writable: _isWritableDir,
      );

  /// Пакетный менеджер определяется по владельцу файла, а не по тому, какой
  /// из них есть в системе: rpm ставят и на Debian, а tar.gz распаковывают
  /// куда угодно.
  @visibleForTesting
  static Future<LinuxInstallKind> classify({
    required String? appImagePath,
    required String executable,
    required Future<bool> Function(String tool, List<String> args) owns,
    required bool Function(String dir) writable,
  }) async {
    if (appImagePath != null) return LinuxInstallKind.appImage;
    if (await owns('dpkg-query', ['-S', executable])) {
      return LinuxInstallKind.deb;
    }
    if (await owns('rpm', ['-qf', executable])) return LinuxInstallKind.rpm;
    if (await owns('pacman', ['-Qo', executable])) {
      return LinuxInstallKind.pacman;
    }
    return writable(p.dirname(executable))
        ? LinuxInstallKind.portable
        : LinuxInstallKind.readOnly;
  }

  static Future<bool> _owns(String tool, List<String> args) async {
    try {
      return (await Process.run(tool, args)).exitCode == 0;
    } on ProcessException {
      return false; // такого менеджера в системе нет
    }
  }

  static bool _isWritableDir(String dir) {
    final probe = File(p.join(dir, '.keqdroid_write_probe_$pid'));
    try {
      probe.writeAsStringSync('');
      probe.deleteSync();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// Ставит скачанный deb или rpm через pkexec и перезапускает приложение.
  /// `true` — процесс уходит на перезапуск, как у
  /// [LinuxAppImageUpdater.applyInPlace].
  ///
  /// deb ставит apt-get, а не dpkg: он доставит зависимости, если их список
  /// сменился. rpm ставит сам rpm: у dnf и zypper разные флаги на
  /// неподписанный локальный пакет, а rpm есть у обоих.
  static Future<bool> installPackage(
    String package, {
    Future<void> Function()? beforeRestart,
  }) async {
    final command = package.endsWith('.deb')
        ? ['apt-get', 'install', '-y', package]
        : ['rpm', '-U', package];
    final ProcessResult result;
    try {
      result = await Process.run('pkexec', command);
    } on ProcessException {
      await OpenFilex.open(package); // без pkexec остаётся установщик системы
      return false;
    }
    switch (result.exitCode) {
      case 0:
        break;
      case 126: // окно пароля закрыли
        return false;
      case 127:
        // Нет агента polkit или политика не пустила: пакет верный, пусть его
        // поставит установщик системы.
        await OpenFilex.open(package);
        return false;
      default:
        throw StateError(
          _tail(result.stderr) ?? 'Package install failed (${result.exitCode})',
        );
    }

    await beforeRestart?.call();
    await launchAfterExit(_relaunchScript, [Platform.resolvedExecutable]);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    exit(0);
  }

  /// Раскладывает скачанный tar.gz поверх папки приложения, когда оно выйдет,
  /// и запускает заново.
  static Future<bool> applyPortable(
    String archive, {
    Future<void> Function()? beforeRestart,
  }) async {
    final appDir = p.dirname(Platform.resolvedExecutable);
    final staging = await Directory.systemTemp.createTemp('keqdroid_update_');
    try {
      final result = await Process.run(
        'tar',
        ['-xzf', archive, '-C', staging.path],
      );
      if (result.exitCode != 0) {
        throw StateError(
          _tail(result.stderr) ?? 'Failed to extract the update archive',
        );
      }
      // Релизный архив кладёт всё в каталог keqdroid/ (tool/package_linux.sh).
      final payload = p.join(staging.path, 'keqdroid');
      if (!File(p.join(payload, 'keqdroid')).existsSync()) {
        throw StateError('Update archive does not contain keqdroid');
      }
      await launchAfterExit(
        _portableScript,
        [payload, appDir, staging.path, archive],
      );
    } catch (_) {
      try {
        await staging.delete(recursive: true);
      } catch (_) {}
      rethrow;
    }

    await beforeRestart?.call();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    exit(0);
  }

  static String? _tail(Object? stderr) {
    final lines = '$stderr'
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) return null;
    return lines.skip(lines.length > 3 ? lines.length - 3 : 0).join('\n');
  }

  static const _relaunchScript = r'''
EXE="$1"
log "=== package update installed, relaunching $EXE"
setsid "$EXE" >/dev/null 2>&1 < /dev/null &
''';

  // Файлы удаляются и кладутся заново, а не пишутся поверх: в запущенный
  // исполняемый файл Linux писать не даёт (Text file busy), а ядро могло
  // выйти позже самого приложения.
  static const _portableScript = r'''
SRC="$1"; DST="$2"; STAGING="$3"; ARCHIVE="$4"
log "=== portable update: $SRC -> $DST"
if cp -a --remove-destination "$SRC/." "$DST/" 2>>"$LOG"; then
  log "copied"
else
  log "copy FAILED"
fi
rm -rf "$STAGING" "$ARCHIVE" 2>/dev/null
setsid "$DST/keqdroid" >/dev/null 2>&1 < /dev/null &
''';
}

/// Запускает [body] отдельным процессом, который дождётся выхода приложения:
/// заменять файлы и поднимать новую копию можно только после него, а новая
/// копия ещё и упёрлась бы в замок единственного экземпляра.
///
/// `setsid` уводит процесс из нашей группы, чтобы `exit(0)` его не прихватил;
/// где setsid нет (минимальные дистрибутивы), хватает отвязанного `sh`.
Future<void> launchAfterExit(String body, List<String> args) async {
  final script = File(p.join(
    Directory.systemTemp.path,
    'keqdroid_update_${DateTime.now().millisecondsSinceEpoch}.sh',
  ));
  await script.writeAsString('$_waitForApp\n$body');
  final shArgs = [script.path, '$pid', ...args];
  try {
    await Process.start('setsid', ['sh', ...shArgs],
        mode: ProcessStartMode.detached);
  } on ProcessException {
    await Process.start('sh', shArgs, mode: ProcessStartMode.detached);
  }
}

const _waitForApp = r'''
APPPID="$1"; shift
LOG="${TMPDIR:-/tmp}/keqdroid_update.log"
log() { printf '%s  %s\n' "$(date -Is 2>/dev/null)" "$1" >>"$LOG" 2>/dev/null; }
i=0
while [ "$i" -lt 120 ]; do
  kill -0 "$APPPID" 2>/dev/null || break
  sleep 1
  i=$((i+1))
done
sleep 1
''';
