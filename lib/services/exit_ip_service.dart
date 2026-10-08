import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../models/ping_test_config.dart';
import '../models/server_flag.dart';
import '../utils/local_vpn_proxy.dart';

/// Адрес, которым подключение видно сайтам, и его страна.
class ExitIp {
  const ExitIp({required this.ip, this.countryCode});

  final String ip;

  /// ISO alpha-2 в верхнем регистре; null — страну Cloudflare не назвал.
  final String? countryCode;

  /// Флаг страны, если для неё есть картинка.
  FlagArt? get flag {
    final code = countryCode?.toLowerCase();
    return code != null && flagArtCodes.contains(code) ? FlagArt(code) : null;
  }
}

/// Узнаёт выход одним запросом к трассировке Cloudflare: она отдаёт и адрес
/// (`ip=`), и страну (`loc=`), а сам адрес приложению уже знаком по замеру
/// пинга — нового стороннего сервиса не появляется.
///
/// Запрос идёт через локальный HTTP-инбаунд ядра. Пакет приложения из туннеля
/// исключён, и прямой запрос показал бы адрес без VPN.
abstract final class ExitIpService {
  static Future<ExitIp?> lookup({
    required int proxyPort,
    Duration timeout = const Duration(seconds: 8),
    @visibleForTesting Uri? traceUrl,
  }) async {
    final url = traceUrl ??
        Uri.parse(
          PingTestConfig.presetUrls[PingTestConfig.targetCloudflare]!,
        );
    final client = HttpClient()..connectionTimeout = timeout;
    configureHttpClientForLocalVpnProxy(client, () => proxyPort);
    try {
      final request = await client.getUrl(url).timeout(timeout);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      return parseTrace(await utf8.decodeStream(response).timeout(timeout));
    } catch (_) {
      // Не ответил — флага просто нет: это подсказка, а не проверка связи.
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Строки `ключ=значение`. Вместо страны Cloudflare бывает пишет `XX`
  /// (не знает) или `T1` (Tor) — флага у таких нет.
  @visibleForTesting
  static ExitIp? parseTrace(String body) {
    String? ip;
    String? loc;
    for (final line in const LineSplitter().convert(body)) {
      final eq = line.indexOf('=');
      if (eq <= 0) continue;
      final value = line.substring(eq + 1).trim();
      switch (line.substring(0, eq)) {
        case 'ip':
          ip = value;
        case 'loc':
          loc = value.toUpperCase();
      }
    }
    if (ip == null || InternetAddress.tryParse(ip) == null) return null;
    final known = loc != null && RegExp(r'^[A-Z]{2}$').hasMatch(loc) && loc != 'XX';
    return ExitIp(ip: ip, countryCode: known ? loc : null);
  }
}
