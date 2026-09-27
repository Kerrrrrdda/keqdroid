import 'awg_profile.dart';
import 'custom_clash_config.dart';
import 'custom_xray_config.dart';
import 'singbox_outbounds.dart';
import 'subscription_deep_link.dart';

/// Делит текст, который пользователь вставил (буфер, файл, QR, deep link), на
/// конфиги серверов.
///
/// Построчно режется только список ссылок. Всё остальное приезжает единым
/// блоком: `.conf` AmneziaWG, json xray (а массив таких объектов — сразу
/// несколько серверов) и yaml Clash. Последний хуже всех: в нём нет ни
/// фигурной скобки в начале, ни строки-ссылки, и построчный разбор превращал
/// один профиль в десятки «неподдерживаемых форматов». Конфиг sing-box —
/// исключение: он раскладывается на ссылки, по одной на узел.
List<String> splitServerImportPayload(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return const [];
  if (AwgProfile.isAwgConfig(text)) return [text];

  // Clash — раньше xray, как и в `validateServerConfig`: json-конфиг Clash тоже
  // начинается с '{', и xray-разбор забрал бы его себе.
  if (CustomClashConfig.looksLikeClash(text)) {
    final clash = CustomClashConfig.extractConfigs(text);
    // Пусто — конфиг похож на clash, но негоден (нет узлов, нет групп у
    // провайдеров, битый YAML). Отдаём целиком: точную причину назовёт
    // `CustomClashConfig.describeProblem` на валидации, а построчно она
    // превратилась бы в «Unsupported format» на каждой строке.
    return clash.isNotEmpty ? clash : [text];
  }

  // sing-box — тоже раньше xray: у его SSR-узла есть поле `protocol`, и
  // xray-разбор счёл бы конфиг своим. Целиком его исполнить нечем, а узлы —
  // те же серверы, что и в подписке. Ни одного нашего узла — отдаём целиком,
  // причину назовёт `validateServerConfig`.
  if (SingboxOutbounds.looksLike(text)) {
    final links = SingboxOutbounds.translate(text).links;
    return links.isNotEmpty ? links : [text];
  }

  final custom = CustomXrayConfig.extractConfigs(text);
  if (custom.isNotEmpty) return custom;

  // json, который конфигом не оказался (ответ панели, обрезанный конфиг):
  // отдаём целиком — так пользователь получит одну внятную причину отказа, а
  // не по ошибке на каждую строку разбитого json.
  if (text.startsWith('{') || text.startsWith('[')) return [text];

  return text
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
}

/// Адрес подписки, если строка вставки — она, иначе null.
///
/// Серверных ссылок на http(s) не бывает, так что такая строка всегда подписка.
/// Без этой проверки кнопка «Вставить ссылку(и)» на пустом экране, где рядом
/// написано про подписки, отвечала на ссылку подписки «неподдерживаемым
/// форматом».
String? subscriptionUrlFromPastedLine(String line) {
  final text = line.trim();
  final fromPanelButton = subscriptionUrlFromDeepLink(text);
  if (fromPanelButton != null) return fromPanelButton;
  final uri = Uri.tryParse(text);
  if (uri == null || uri.host.isEmpty) return null;
  return uri.isScheme('http') || uri.isScheme('https') ? text : null;
}
