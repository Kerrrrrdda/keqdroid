// Routing lists are now mixed: a single field may contain domains, IP/CIDR
// ranges and prefixed rules (geosite:/geoip:/full:/regexp:). This helper splits
// a parsed list into the domain-shaped tokens and the ip-shaped tokens so the
// xray / sing-box config generators can emit the right rule kind for each.

final _ipV4 = RegExp(r'^(\d{1,3}\.){3}\d{1,3}(/\d{1,2})?$');
final _ipV6 = RegExp(r'^[0-9a-fA-F:]+(/\d{1,3})?$');

/// True for an IPv4/IPv6 address or CIDR range.
bool looksLikeIpOrCidr(String value) {
  final v = value.trim();
  if (v.isEmpty) return false;
  if (_ipV4.hasMatch(v)) return true;
  // ipv6 must contain a colon to avoid matching bare hostnames/labels.
  if (v.contains(':') && _ipV6.hasMatch(v)) return true;
  return false;
}

/// Приватные, LAN- и служебные диапазоны: всегда напрямую. Своими адресами в
/// списках их не считают — пресет «Локальная сеть» кладёт их в обход, и
/// стратегия резолва от этого подниматься не должна. Список общий на оба
/// генератора, чтобы «свои адреса» у ядер не разъехались.
const Set<String> kBasePrivateRanges = {
  '0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8',
  '169.254.0.0/16', '172.16.0.0/12', '172.19.0.0/30',
  '192.0.0.0/24', '192.168.0.0/16',
  '198.51.100.0/24', '203.0.113.0/24',
  '::1/128', 'fc00::/7', 'fe80::/10',
};

/// Делит записи роутинга на доменные и адресные.
///
/// В [ips] уходят `geoip:*` (ядро сопоставляет их как ip-правила), адреса и
/// диапазоны CIDR. Всё остальное — голые хосты, `.суффиксы`, `domain:`, `full:`,
/// `regexp:`, `geosite:` — это [domains], их нормализуют дальше по цепочке.
({List<String> domains, List<String> ips}) splitDomainsAndIps(
  List<String> entries,
) {
  final domains = <String>[];
  final ips = <String>[];
  for (final raw in entries) {
    final v = raw.trim();
    if (v.isEmpty) continue;
    if (v.toLowerCase().startsWith('geoip:')) {
      ips.add(v);
      continue;
    }
    if (looksLikeIpOrCidr(v)) {
      ips.add(v);
      continue;
    }
    domains.add(v);
  }
  return (domains: domains, ips: ips);
}

/// Pulls `geoip:XX` tokens out of [ips] for proper xray `geoip` rules.
/// Plain IPv4/IPv6/CIDR entries stay in [plainIps].
({List<String> plainIps, List<String> geoipCodes}) splitGeoipTokens(
  List<String> ips,
) {
  final plainIps = <String>[];
  final geoipCodes = <String>[];
  for (final raw in ips) {
    final v = raw.trim();
    if (v.isEmpty) continue;
    final lower = v.toLowerCase();
    if (lower.startsWith('geoip:')) {
      final code = v.substring('geoip:'.length).trim();
      if (code.isNotEmpty) geoipCodes.add(code);
      continue;
    }
    plainIps.add(v);
  }
  return (plainIps: plainIps, geoipCodes: geoipCodes);
}
