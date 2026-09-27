import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/services/app_log_service.dart';

void main() {
  group('журнал приложения и нативной части', () {
    // Формат общий: так пишут и AppLogger в Dart, и NativeLog в Kotlin.
    const text = '2026-09-27T22:51:39.123456 [INFO] VPN connected\n'
        '2026-09-27T22:51:40.000 [ERROR] KEQDIS: startVpn failed: boom\n'
        'java.lang.IllegalStateException: boom\n'
        '\tat com.keqdroid.keqdroid.KeqdisVpnService.startXray(Unknown)\n'
        '2026-09-27T22:51:41.000 [WARN] handover: mihomo API did not answer\n'
        '2026-09-27T22:51:42.000 [DEBUG] syncFromNative failed\n';

    test('записи с уровнями, стек остаётся при своей ошибке', () {
      final entries = AppLogService.parse(AppLogSource.native, text);

      expect(entries.map((e) => e.level), [
        LogLevel.info,
        LogLevel.error,
        LogLevel.warn,
        LogLevel.debug,
      ]);
      expect(entries[1].text, contains('startVpn failed'));
      expect(entries[1].text, contains('\tat com.keqdroid.keqdroid'));
      expect(entries[2].text, isNot(contains('\tat')));
    });

    test('проблемы — это предупреждения и ошибки', () {
      final problems = AppLogService.parse(AppLogSource.app, text)
          .where((e) => e.isProblem)
          .map((e) => e.level);
      expect(problems, [LogLevel.error, LogLevel.warn]);
    });

    test('хвост записи, начало которой срезал предел чтения, не теряется', () {
      final entries = AppLogService.parse(
        AppLogSource.app,
        '\tat some.Frame(Unknown)\n2026-09-27T22:51:39.1 [INFO] next\n',
      );
      expect(entries.first.text, '\tat some.Frame(Unknown)');
      expect(entries.last.text, contains('next'));
    });

    test('пустой журнал — пустой список', () {
      expect(AppLogService.parse(AppLogSource.app, ''), isEmpty);
      expect(AppLogService.parse(AppLogSource.core, '\n\n'), isEmpty);
    });
  });

  group('уровень строки ядра', () {
    LogLevel level(String line) => AppLogService.coreLevel(line);

    test('xray — в скобках', () {
      expect(level('09-27 22:51:42 2026/09/27 18:51:42 [Error] app: failed'),
          LogLevel.error);
      expect(level('09-27 22:51:42 2026/09/27 18:51:42 [Warning] proxy: dial'),
          LogLevel.warn);
      expect(level('09-27 22:51:42 2026/09/27 18:51:42 [Debug] geodata: hit'),
          LogLevel.debug);
      expect(level('09-27 22:51:42 2026/09/27 18:51:42 [Info] started'),
          LogLevel.info);
    });

    test('mihomo — полем level', () {
      expect(level('time="2026" level=error msg="dial failed"'), LogLevel.error);
      expect(level('time="2026" level=warning msg="slow"'), LogLevel.warn);
      expect(level('time="2026" level=info msg="ok"'), LogLevel.info);
    });

    test('sing-box на десктопе — словом капсом', () {
      expect(level('+0300 2026-09-27 22:51:42 ERROR [123] inbound failed'),
          LogLevel.error);
      expect(level('+0300 2026-09-27 22:51:42 WARN dns: timeout'), LogLevel.warn);
    });

    test('«error» строчными в тексте строки Info уровень не меняет', () {
      expect(
        level('[Info] transport/internet: connection error, retrying'),
        LogLevel.info,
      );
    });

    test('заметки службы о ядре — всегда проблема', () {
      expect(level('09-27 22:51:42 [keqdis] core process 5542 is gone'),
          LogLevel.warn);
    });
  });
}
