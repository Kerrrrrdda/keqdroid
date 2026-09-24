/// Перевод полей, которые xray объявил к удалению, в их новую запись — для
/// готовых конфигов провайдеров.
///
/// Удалённое поле ядро не игнорирует, а отказывается запускать конфиг целиком:
/// так уже случилось с `allowInsecure` (см. removed_tls_fields). Пока поля
/// живы, ядро само переводит их в новую запись и пишет предупреждение. Здесь
/// тот же перевод делается заранее, по его же правилам, чтобы конфиг
/// провайдера пережил обновление ядра. То, что ядро и сегодня отвергло бы, не
/// трогаем: наш перевод не должен ни чинить ошибку автора, ни прятать её.
library;

/// Переводит устаревшие поля в аутбаундах [config] на месте.
///
/// Возвращает число переведённых мест: ноль — переводить было нечего.
int migrateDeprecatedXrayFields(Map<String, dynamic> config) {
  final outbounds = config['outbounds'];
  if (outbounds is! List) return 0;
  var migrated = 0;
  for (final outbound in outbounds) {
    if (outbound is! Map) continue;
    final protocol = outbound['protocol']?.toString().toLowerCase();
    if (protocol == 'dns' && _migrateDnsOutbound(outbound)) migrated++;
    if (protocol == 'freedom' && _migrateFreedomStrategy(outbound)) migrated++;
    if (_migrateWsHost(outbound)) migrated++;
  }
  return migrated;
}

/// `nonIPQuery`/`blockTypes` у `dns`-аутбаунда → `rules`, как их разворачивает
/// ядро (`buildLegacyDNSPolicy`): сначала блокируемые типы, потом A/AAAA в
/// DNS-модуль, потом всё прочее по режиму. Вместе с `rules` старые поля ядро не
/// принимает вовсе — такой конфиг оставляем как есть.
bool _migrateDnsOutbound(Map<dynamic, dynamic> outbound) {
  final settings = outbound['settings'];
  if (settings is! Map) return false;
  if (!settings.containsKey('nonIPQuery') &&
      !settings.containsKey('blockTypes')) {
    return false;
  }
  if (settings.containsKey('rules')) return false;

  final rawMode = settings['nonIPQuery'];
  if (rawMode != null && rawMode is! String) return false;
  final mode = rawMode is String && rawMode.isNotEmpty ? rawMode : 'reject';
  if (!const {'reject', 'drop', 'skip'}.contains(mode)) return false;

  final rawTypes = settings['blockTypes'];
  if (rawTypes != null && rawTypes is! List) return false;
  final types = <int>[];
  for (final t in (rawTypes as List?) ?? const []) {
    if (t is! int || t < 0 || t > 65535) return false;
    types.add(t);
  }

  settings
    ..remove('nonIPQuery')
    ..remove('blockTypes')
    ..['rules'] = [
      if (types.isNotEmpty)
        mode == 'reject'
            ? {'action': 'return', 'rCode': 5, 'qType': types.join(',')}
            : {'action': 'drop', 'qType': types.join(',')},
      {'action': 'hijack', 'qType': '1,28'},
      switch (mode) {
        'drop' => {'action': 'drop'},
        'skip' => {'action': 'direct'},
        _ => {'action': 'return', 'rCode': 5},
      },
    ];
  return true;
}

/// Значения стратегии, которые ядро принимает и у freedom, и в `sockopt`.
const _strategies = {
  '',
  'asis',
  'useip',
  'useipv4',
  'useipv6',
  'useipv4v6',
  'useipv6v4',
  'forceip',
  'forceipv4',
  'forceipv6',
  'forceipv4v6',
  'forceipv6v4',
};

/// `domainStrategy`/`targetStrategy` в настройках freedom → `sockopt`.
///
/// Ядро берёт `targetStrategy`, а при пустом — `domainStrategy`, и кладёт
/// значение в `sockopt.domainStrategy` поверх того, что там было. Но если на
/// самом аутбаунде стоит свой `targetStrategy`, побеждает он, а поле freedom
/// ядро не читает вовсе — тогда его просто убираем.
bool _migrateFreedomStrategy(Map<dynamic, dynamic> outbound) {
  final settings = outbound['settings'];
  if (settings is! Map) return false;
  if (!settings.containsKey('domainStrategy') &&
      !settings.containsKey('targetStrategy')) {
    return false;
  }
  final target = settings['targetStrategy'];
  final domain = settings['domainStrategy'];
  if ((target != null && target is! String) ||
      (domain != null && domain is! String)) {
    return false;
  }
  final value = target is String && target.isNotEmpty
      ? target
      : (domain is String ? domain : '');
  if (!_strategies.contains(value.toLowerCase())) return false;

  settings
    ..remove('targetStrategy')
    ..remove('domainStrategy');
  if (const {'', 'asis'}.contains(value.toLowerCase())) return true;

  final outer = outbound['targetStrategy'];
  if (outer is String && !const {'', 'asis'}.contains(outer.toLowerCase())) {
    return true;
  }

  final stream = outbound['streamSettings'] is Map
      ? outbound['streamSettings'] as Map
      : (outbound['streamSettings'] = <String, dynamic>{});
  final sockopt = stream['sockopt'] is Map
      ? stream['sockopt'] as Map
      : (stream['sockopt'] = <String, dynamic>{});
  sockopt['domainStrategy'] = value;
  return true;
}

/// `Host` в `headers` у WebSocket → отдельное `host`.
///
/// Ядро удаляет из заголовков каждое написание `Host` и берёт его значение,
/// только если своего `host` нет. Пустые после этого заголовки ему всё равно
/// что отсутствующие — убираем и их.
bool _migrateWsHost(Map<dynamic, dynamic> outbound) {
  final stream = outbound['streamSettings'];
  if (stream is! Map) return false;
  final ws = stream['wsSettings'];
  if (ws is! Map) return false;
  final headers = ws['headers'];
  if (headers is! Map) return false;
  final hostKeys = [
    for (final key in headers.keys)
      if (key.toString().toLowerCase() == 'host') key,
  ];
  if (hostKeys.isEmpty) return false;
  if (hostKeys.any((k) => headers[k] is! String)) return false;

  final own = ws['host'];
  if (own != null && own is! String) return false;
  if (own is! String || own.isEmpty) ws['host'] = headers[hostKeys.first];
  for (final key in hostKeys) {
    headers.remove(key);
  }
  if (headers.isEmpty) ws.remove('headers');
  return true;
}
