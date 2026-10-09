/// Записи раздельного туннелирования и строки списка программ.
///
/// Запись бывает двух видов. С путём — «только этот файл»: так сохраняется
/// программа, выбранная из списка или через «Обзор…». Без пути — «любая
/// программа с таким именем»: так сохраняется вписанное руками, и так же
/// лежат записи всех прошлых версий. Строка списка отмечена, если с ней
/// совпала любая из двух.
///
/// Имена приходят в разном виде: список процессов Windows отдаёт `Discord.exe`
/// с настоящим регистром, а у давних пользователей сохранён `discord.exe` —
/// так писала старая версия. Для правил ядра это одно имя
/// (`processNameMatchVariants` шлёт оба варианта регистра), поэтому и здесь.
library;

import 'dart:io' show Platform;

import '../models/app_info.dart';
import 'process_name_utils.dart';

/// Ключ имени: регистр снимаем после нормализации — только после неё имена
/// из разных источников сравнимы.
String splitNameKey(String raw, {bool? windows}) =>
    normalizeProcessName(raw, windows: windows).toLowerCase();

/// Ключ пути. Регистр снимается только на Windows: там путь к файлу от
/// регистра не зависит, а на Linux `/opt/App` и `/opt/app` — разные файлы.
String splitPathKey(String raw, {bool? windows}) {
  final onWindows = windows ?? Platform.isWindows;
  final path = normalizeProcessPath(raw, windows: onWindows);
  return onWindows ? path.toLowerCase() : path;
}

bool _hasPath(AppInfo app) =>
    app.installPath != null && app.installPath!.isNotEmpty;

/// Совпадает ли сохранённая запись со строкой списка.
bool splitEntryMatches(String entry, AppInfo app, {bool? windows}) {
  if (entry.trim().isEmpty) return false;
  if (isProcessPathEntry(entry)) {
    return _hasPath(app) &&
        splitPathKey(entry, windows: windows) ==
            splitPathKey(app.installPath!, windows: windows);
  }
  return splitNameKey(entry, windows: windows) ==
      splitNameKey(app.packageName, windows: windows);
}

/// Что сохранить, когда строку отмечают: путь, если он у строки есть, иначе
/// имя. Пути нет у программ на Android и у строк, собранных из вписанного
/// руками имени.
String splitEntryForApp(AppInfo app, {bool? windows}) => _hasPath(app)
    ? normalizeProcessPath(app.installPath!, windows: windows)
    : app.packageName;

/// Отмеченные записи, разобранные один раз на построение списка: строк там
/// сотни, и сверять каждую со всеми записями заново незачем.
class SplitSelection {
  SplitSelection(Iterable<String> entries, {bool? windows})
      : _windows = windows {
    for (final entry in entries) {
      if (entry.trim().isEmpty) continue;
      if (isProcessPathEntry(entry)) {
        _paths.add(splitPathKey(entry, windows: windows));
      } else {
        _names.add(splitNameKey(entry, windows: windows));
      }
    }
  }

  final bool? _windows;
  final _paths = <String>{};
  final _names = <String>{};

  bool covers(AppInfo app) =>
      (_hasPath(app) &&
          _paths.contains(splitPathKey(app.installPath!, windows: _windows))) ||
      _names.contains(splitNameKey(app.packageName, windows: _windows));
}

/// Строка списка для записи, которой нет среди программ системы.
AppInfo splitStubForEntry(String entry, {bool? windows}) {
  if (isProcessPathEntry(entry)) {
    final path = normalizeProcessPath(entry, windows: windows);
    final name = normalizeProcessName(path, windows: windows);
    return AppInfo(packageName: name, appName: name, installPath: path);
  }
  return AppInfo(
    packageName: normalizeProcessName(entry, windows: windows),
    appName: entry.trim(),
  );
}

/// Схлопывает повторы строк, сохраняя порядок.
///
/// Одно имя с разными путями — разные программы, и обе остаются: ради этого
/// путь и сохраняется. Строка без пути при живой строке того же имени
/// уходит: это заглушка, собранная из сохранённого имени, а у живой есть
/// иконка.
List<AppInfo> dedupeSplitEntries(List<AppInfo> apps, {bool? windows}) {
  final withPath = <String>{};
  final namesWithPath = <String>{};
  for (final app in apps) {
    if (_hasPath(app)) {
      namesWithPath.add(splitNameKey(app.packageName, windows: windows));
    }
  }
  final pathless = <String>{};
  final out = <AppInfo>[];
  for (final app in apps) {
    final name = splitNameKey(app.packageName, windows: windows);
    if (name.isEmpty) continue;
    if (_hasPath(app)) {
      if (withPath.add(splitPathKey(app.installPath!, windows: windows))) {
        out.add(app);
      }
    } else if (!namesWithPath.contains(name) && pathless.add(name)) {
      out.add(app);
    }
  }
  return out;
}
