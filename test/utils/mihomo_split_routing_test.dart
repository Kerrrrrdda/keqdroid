import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/tunnel/app_routing_mode.dart';
import 'package:keqdroid/utils/mihomo_config_gen.dart';
import 'package:keqdroid/utils/socks5_credentials.dart';

/// Сплит по приложениям на mihomo в десктопном TUN.
///
/// Правило «это приложение — в VPN» стояло первым, и до списков сайтов
/// выбранные приложения не доходили: yandex.ru из Firefox уезжал через сервер
/// при «Напрямую: ru». А невыбранные шли по спискам и попадали в VPN по «Через
/// VPN». Теперь как у keqrnel и на Android: невыбранные — мимо туннеля целиком,
/// выбранные — по спискам и «Всё остальное».
const _link = 'ss://YWVzLTI1Ni1nY206dGVzdHBhc3M@203.0.113.10:8388#t';

List<String> _rules({
  required AppRoutingMode mode,
  List<String> apps = const ['firefox.exe', 'Telegram.exe'],
  String finalOutbound = AppSettings.finalOutboundProxy,
}) {
  Socks5Credentials().init('u', 'p');
  return (MihomoConfigGen.build(
    _link,
    AppSettings(
      directRules: 'ru, yandex.ru',
      proxyRules: 'telegram.org',
      blockedRules: 'doubleclick.net',
      finalOutbound: finalOutbound,
    ),
    socksPort: 2080,
    httpPort: 2081,
    tun: const MihomoTunOptions(device: 'tun-keqdis', stack: 'gvisor'),
    routingMode: mode,
    managedProcessNames: apps,
    appProcessName: 'keqdroid.exe',
    windows: true,
  )['rules'] as List)
      .cast<String>();
}

/// Куда mihomo отправит соединение [process] → [host]: первое совпавшее
/// правило. Понимает типы, которые здесь бывают у соединения по домену; IP- и
/// geo-правила пропускает — домены теста ни в один диапазон не попадают.
String _route(List<String> rules, String process, String host) {
  for (final rule in rules) {
    final fields = rule.split(',');
    final type = fields.first;
    final matched = switch (type) {
      'MATCH' => true,
      'PROCESS-NAME' => fields[1].toLowerCase() == process.toLowerCase(),
      // Как в ядре: regexp2 с IgnoreCase (rules/common/process.go).
      'PROCESS-NAME-REGEX' =>
        RegExp(fields[1], caseSensitive: false).hasMatch(process),
      'DOMAIN' => host == fields[1],
      'DOMAIN-SUFFIX' => host == fields[1] || host.endsWith('.${fields[1]}'),
      _ => false,
    };
    if (matched) return type == 'MATCH' ? fields[1] : fields[2];
  }
  fail('в правилах нет MATCH');
}

void main() {
  group('только выбранные', () {
    test('выбранное приложение идёт по спискам сайтов', () {
      final rules = _rules(mode: AppRoutingMode.onlySelected);
      expect(_route(rules, 'firefox.exe', 'yandex.ru'), 'DIRECT');
      expect(_route(rules, 'firefox.exe', 'mail.ru'), 'DIRECT');
      expect(_route(rules, 'firefox.exe', 'telegram.org'), 'proxy');
      expect(_route(rules, 'firefox.exe', 'doubleclick.net'), 'REJECT');
    });

    test('остальной трафик выбранного — куда велит «Всё остальное»', () {
      expect(
        _route(_rules(mode: AppRoutingMode.onlySelected), 'firefox.exe',
            'example.com'),
        'proxy',
      );
      expect(
        _route(
          _rules(
            mode: AppRoutingMode.onlySelected,
            finalOutbound: AppSettings.finalOutboundDirect,
          ),
          'firefox.exe',
          'example.com',
        ),
        'DIRECT',
      );
    });

    test('невыбранное приложение идёт мимо VPN целиком', () {
      final rules = _rules(mode: AppRoutingMode.onlySelected);
      for (final host in ['telegram.org', 'example.com', 'yandex.ru']) {
        expect(_route(rules, 'chrome.exe', host), 'DIRECT', reason: host);
      }
      // И то, чей процесс ядро не узнало.
      expect(_route(rules, '', 'telegram.org'), 'DIRECT');
    });

    test('регистр имени не важен, подстрока не считается', () {
      final rules = _rules(mode: AppRoutingMode.onlySelected);
      expect(_route(rules, 'FIREFOX.EXE', 'example.com'), 'proxy');
      expect(_route(rules, 'telegram.exe', 'example.com'), 'proxy');
      for (final other in ['firefoxXexe', 'myfirefox.exe', 'firefox.exe.bak']) {
        expect(_route(rules, other, 'example.com'), 'DIRECT', reason: other);
      }
    });

    // Скобка ломала разбор логических правил, запятая — любого: ядро не
    // запускалось вовсе («proxy [b.exe] not found»).
    test('скобки, запятые и пробелы в имени не ломают правило', () {
      const apps = ['App (x86).exe', 'a,b.exe', 'My App.exe'];
      final rules = _rules(mode: AppRoutingMode.onlySelected, apps: apps);
      final split = rules.where((r) => r.startsWith('PROCESS-NAME-REGEX,'));
      expect(split, hasLength(1));
      expect(split.single.split(','), hasLength(3));
      expect(split.single, isNot(contains('(x86)')),
          reason: 'скобки из имён должны быть закодированы');
      for (final app in apps) {
        expect(_route(rules, app, 'example.com'), 'proxy', reason: app);
      }
      expect(_route(rules, 'App x86.exe', 'example.com'), 'DIRECT');
    });

    // На Linux имена процессов в генератор пока не передаются, и сплит там
    // остаётся прежним: списки и финал DIRECT.
    test('без имён процессов всё как было', () {
      final rules = _rules(mode: AppRoutingMode.onlySelected, apps: const []);
      expect(rules.last, 'MATCH,DIRECT');
      expect(rules.any((r) => r.startsWith('PROCESS-NAME-REGEX')), isFalse);
      expect(_route(rules, 'firefox', 'telegram.org'), 'proxy');
    });
  });

  group('все, кроме выбранных', () {
    test('исключённое приложение идёт мимо VPN целиком', () {
      final rules = _rules(mode: AppRoutingMode.allExceptSelected);
      expect(_route(rules, 'Telegram.exe', 'telegram.org'), 'DIRECT');
      expect(_route(rules, 'telegram.exe', 'example.com'), 'DIRECT');
    });

    test('остальные идут по спискам и «Всё остальное»', () {
      final rules = _rules(mode: AppRoutingMode.allExceptSelected);
      expect(_route(rules, 'chrome.exe', 'yandex.ru'), 'DIRECT');
      expect(_route(rules, 'chrome.exe', 'telegram.org'), 'proxy');
      expect(_route(rules, 'chrome.exe', 'example.com'), 'proxy');
      final direct = _rules(
        mode: AppRoutingMode.allExceptSelected,
        finalOutbound: AppSettings.finalOutboundDirect,
      );
      expect(_route(direct, 'chrome.exe', 'example.com'), 'DIRECT');
      expect(_route(direct, 'chrome.exe', 'telegram.org'), 'proxy');
    });

    test('запятая в имени не роняет конфиг', () {
      final rules = _rules(
        mode: AppRoutingMode.allExceptSelected,
        apps: const ['a,b.exe'],
      );
      final split = rules.where((r) => r.startsWith('PROCESS-NAME-REGEX,'));
      expect(split.single.split(','), hasLength(3));
      expect(_route(rules, 'a,b.exe', 'telegram.org'), 'DIRECT');
    });
  });

  test('готовый Clash-конфиг: невыбранные мимо VPN, выбранные по правилам',
      () {
    const clash = '''
proxies:
  - {name: p1, type: ss, server: 203.0.113.10, port: 8388, cipher: aes-256-gcm, password: x}
proxy-groups:
  - {name: G, type: select, proxies: [p1]}
rules:
  - DOMAIN-SUFFIX,author-direct.example,DIRECT
  - MATCH,G
''';
    Socks5Credentials().init('u', 'p');
    final rules = (MihomoConfigGen.build(
      clash,
      const AppSettings(),
      socksPort: 2080,
      httpPort: 2081,
      tun: const MihomoTunOptions(device: 'tun-keqdis', stack: 'gvisor'),
      routingMode: AppRoutingMode.onlySelected,
      managedProcessNames: const ['firefox.exe'],
      appProcessName: 'keqdroid.exe',
      windows: true,
    )['rules'] as List)
        .cast<String>();
    expect(_route(rules, 'firefox.exe', 'author-direct.example'), 'DIRECT');
    expect(_route(rules, 'firefox.exe', 'example.com'), 'G');
    expect(_route(rules, 'chrome.exe', 'example.com'), 'DIRECT');
  });
}
