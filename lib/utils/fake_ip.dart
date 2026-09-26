/// Общее для fake-ip всех трёх генераторов: из какого диапазона берутся
/// подменные адреса и кому они не выдаются никогда.
library;

/// Диапазон подменных адресов у xray и sing-box — тот же 198.18/16, что у
/// mihomo. У mihomo он записан с адресом `.1` (`MihomoConfigGen.fakeIpRange`),
/// потому что оттуда же mihomo берёт адрес своего tun-интерфейса.
const kFakeIpRange = '198.18.0.0/16';

/// Домены, которым подменный адрес не выдаётся никогда, — в синтаксисе
/// `fake-ip-filter` mihomo (`*.` — поддомены, `*` внутри — одна метка).
///
/// Первые — локальные зоны: к ним ходят по настоящему адресу в своей сети.
/// Остальные — проверки связности Android, Windows и Apple: получив адрес, по
/// которому никто не отвечает, система решает, что сети нет, и рисует
/// «интернета нет» поверх работающего туннеля.
const kFakeIpFilter = <String>[
  '*.lan',
  '*.local',
  '*.localdomain',
  '*.home.arpa',
  'localhost',
  'connectivitycheck.gstatic.com',
  '*.msftconnecttest.com',
  '*.msftncsi.com',
  'captive.apple.com',
  'time.*.com',
  '*.ntp.org',
];

/// [kFakeIpFilter] в синтаксисе правил xray (`full:`, `domain:`, `regexp:`),
/// который понимают и списки маршрутизации приложения, и генератор sing-box.
///
/// `*.x` становится `domain:x`: это ещё и сам `x`, то есть шире, чем у mihomo,
/// но для списка «не подменять» лишний настоящий адрес безвреден.
List<String> fakeIpFilterAsRules() => [
      for (final pattern in kFakeIpFilter) _asRule(pattern),
    ];

String _asRule(String pattern) {
  if (!pattern.contains('*')) return 'full:$pattern';
  final rest = pattern.substring(2);
  if (pattern.startsWith('*.') && !rest.contains('*')) return 'domain:$rest';
  final labels = [
    for (final label in pattern.split('.'))
      label == '*' ? '[^.]+' : RegExp.escape(label),
  ];
  return 'regexp:^${labels.join(r'\.')}\$';
}
