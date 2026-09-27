import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/app_logger.dart';
import '../models/app_internals.dart';
import 'app_internals_service.dart';
import 'debug_log_service.dart';

/// Часть приложения, чей журнал показывает «Журнал приложения».
enum AppLogSource {
  /// Dart: интерфейс и логика — `app.log`.
  app,

  /// Android: служба VPN, плитка, окно подключения — `native.log`.
  native,
}

enum LogLevel { debug, info, warn, error }

/// Одна запись журнала. [text] бывает в несколько строк: ошибка со стеком.
class LogEntry {
  const LogEntry(this.level, this.text);

  final LogLevel level;
  final String text;

  /// То, ради чего журнал и открывают, — «что упало».
  bool get isProblem => level == LogLevel.warn || level == LogLevel.error;
}

/// Журналы разных частей приложения — прочитать, разобрать, собрать в один
/// текст для отправки.
///
/// Части разнесены намеренно: на телефоне в общей куче строк нативной службы
/// и Dart не найти, какая из них сломалась, а вопрос почти всегда именно такой.
///
/// Вывода ядра среди частей нет: он живёт на экране отладочного режима, и
/// показывать его каждому, минуя этот режим, незачем.
class AppLogService {
  AppLogService._();

  static const _channel = MethodChannel('keqdis_vpn_channel');

  /// Журналы этой платформы. Нативная часть со своим журналом есть только на
  /// Android.
  static List<AppLogSource> get sources => [
        AppLogSource.app,
        if (Platform.isAndroid) AppLogSource.native,
      ];

  static Future<List<LogEntry>> read(AppLogSource source) async =>
      parse(source, await _readRaw(source));

  static Future<String> _readRaw(AppLogSource source) async {
    try {
      return switch (source) {
        AppLogSource.app => await AppLogger.instance.readFileLog(),
        AppLogSource.native =>
          await _channel.invokeMethod<String>('getNativeLog') ?? '',
      };
    } catch (_) {
      // Натив старый или канал не ответил — журнала этой части просто нет.
      return '';
    }
  }

  /// Начало записи в `app.log` и `native.log`: оба пишут одинаково.
  static final _head =
      RegExp(r'^\d{4}-\d{2}-\d{2}T\S+ \[(DEBUG|INFO|WARN|ERROR)\] ');

  static List<LogEntry> parse(AppLogSource source, String text) {
    final lines = const LineSplitter().convert(text);
    final entries = <LogEntry>[];
    for (final line in lines) {
      final head = _head.firstMatch(line);
      if (head != null) {
        entries.add(LogEntry(_levels[head.group(1)]!, line));
      } else if (entries.isNotEmpty) {
        // Продолжение прошлой записи: стек или многострочная ошибка.
        final last = entries.removeLast();
        entries.add(LogEntry(last.level, '${last.text}\n$line'));
      } else if (line.trim().isNotEmpty) {
        // Хвост записи, начало которой срезал предел чтения.
        entries.add(LogEntry(LogLevel.info, line));
      }
    }
    return entries;
  }

  static const _levels = {
    'DEBUG': LogLevel.debug,
    'INFO': LogLevel.info,
    'WARN': LogLevel.warn,
    'ERROR': LogLevel.error,
  };

  /// Весь журнал одним текстом — для чата поддержки.
  ///
  /// Из каждой части только хвост: полмегабайта app.log в сообщение не
  /// влезут, а причина почти всегда в последних строках. Закрытия процесса
  /// целиком — их система хранит всего десяток.
  static Future<String> bundle({int tailEntries = 300}) async {
    final out = StringBuffer('# keqdroid log\n');
    for (final source in sources) {
      final entries = await read(source);
      final tail = entries.length > tailEntries
          ? entries.sublist(entries.length - tailEntries)
          : entries;
      out
        ..writeln()
        ..writeln('## ${source.name}');
      for (final entry in tail) {
        out.writeln(entry.text);
      }
    }
    // Ядра в самом журнале нет, а в текст для поддержки его хвост идёт: при
    // «не подключается» причину пишет именно оно.
    final core = await _coreTail(tailEntries);
    if (core.isNotEmpty) {
      out
        ..writeln()
        ..writeln('## core')
        ..writeln(core);
    }
    final exits = await processExits();
    if (exits.isNotEmpty) {
      out
        ..writeln()
        ..writeln('## process exits')
        ..write(AppInternalsService.exitLines(exits));
    }
    return out.toString();
  }

  static Future<List<ProcessExit>> processExits() =>
      AppInternalsService.processExits();

  static Future<String> _coreTail(int lines) async {
    try {
      return (await DebugLogService.getXrayLogs(maxLines: lines)).trim();
    } catch (_) {
      return '';
    }
  }
}
