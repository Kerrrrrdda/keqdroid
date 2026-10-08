import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/tunnel/app_routing_mode.dart';
import 'package:keqdroid/utils/singbox_tun_config.dart';

/// Сплит по приложениям в десктопном TUN на keqrnel.
///
/// Выбранные приложения уходят во встроенный xray, и списки сайтов с «Всё
/// остальное» исполняет он. Невыбранные шли дальше по спискам sing-box и
/// попадали в VPN по «Через VPN», хотя их не выбирали. Теперь они идут мимо
/// туннеля целиком, как на Android.
Map<String, dynamic> _route({
  required AppRoutingMode mode,
  List<String> apps = const ['firefox.exe'],
}) {
  final config = jsonDecode(SingBoxTunConfigGen.generate(
    localSocksPort: 2080,
    socksUsername: 'u',
    socksPassword: 'p',
    serverIpToExclude: '198.51.100.10',
    settings: const AppSettings(
      directRules: 'direct.example',
      proxyRules: 'proxy.example',
      blockedRules: 'ads.example',
    ),
    managedProcessNames: apps,
    routingMode: mode,
    appProcessName: 'keqdroid.exe',
    windows: true,
  )) as Map<String, dynamic>;
  return config['route'] as Map<String, dynamic>;
}

/// Куда sing-box отправит TLS-соединение [process] → [host]: первое правило с
/// маршрутом, условия которого совпали. Соединение приходит доменом, поэтому
/// правила по IP и DNS-перехват сюда не относятся.
String _where(Map<String, dynamic> route, String process, String host) {
  bool inList(Object? list, bool Function(String) test) =>
      list is List && list.cast<String>().any(test);

  for (final raw in route['rules'] as List) {
    final rule = raw as Map<String, dynamic>;
    final action = rule['action'] ?? 'route';
    if (action != 'route' && action != 'reject') continue;
    if (rule.containsKey('ip_cidr') ||
        rule.containsKey('protocol') ||
        rule.containsKey('port')) {
      continue;
    }
    if (rule.containsKey('process_name') &&
        !inList(rule['process_name'], (n) => n == process)) {
      continue;
    }
    if (rule.containsKey('domain_suffix') &&
        !inList(rule['domain_suffix'],
            (s) => host == s || host.endsWith('.$s'))) {
      continue;
    }
    if (rule.containsKey('domain') &&
        !inList(rule['domain'], (d) => d == host)) {
      continue;
    }
    return action == 'reject' ? 'block' : rule['outbound'] as String;
  }
  return route['final'] as String;
}

void main() {
  group('только выбранные', () {
    test('выбранное приложение целиком уходит в xray', () {
      final route = _route(mode: AppRoutingMode.onlySelected);
      for (final host in ['direct.example', 'proxy.example', 'other.example']) {
        expect(_where(route, 'firefox.exe', host), 'proxy', reason: host);
      }
    });

    test('невыбранное идёт мимо VPN целиком, списки к нему не относятся', () {
      final route = _route(mode: AppRoutingMode.onlySelected);
      expect(_where(route, 'chrome.exe', 'proxy.example'), 'direct');
      expect(_where(route, 'chrome.exe', 'other.example'), 'direct');
      expect(_where(route, 'chrome.exe', 'ads.example'), 'direct');
    });

    // На Linux имена процессов в генератор пока не передаются.
    test('без имён процессов списки действуют, как было', () {
      final route = _route(mode: AppRoutingMode.onlySelected, apps: const []);
      expect(_where(route, 'chrome.exe', 'proxy.example'), 'proxy');
      expect(_where(route, 'chrome.exe', 'ads.example'), 'block');
      expect(_where(route, 'chrome.exe', 'other.example'), 'direct');
    });
  });

  test('все, кроме выбранных — без изменений', () {
    final route = _route(
      mode: AppRoutingMode.allExceptSelected,
      apps: const ['telegram.exe'],
    );
    expect(_where(route, 'telegram.exe', 'proxy.example'), 'direct');
    expect(_where(route, 'chrome.exe', 'proxy.example'), 'proxy');
    expect(_where(route, 'chrome.exe', 'direct.example'), 'direct');
    expect(_where(route, 'chrome.exe', 'other.example'), 'proxy');
  });
}
