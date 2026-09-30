import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'socks5_credentials.dart';

/// Порт локального HTTP-инбаунда ядра, через который прямо сейчас можно выйти
/// в сеть, либо null — «идти напрямую».
///
/// Спрашивается на каждый запрос, а не при сборке клиента: VPN включают и
/// выключают посреди жизни сервиса (сервис подписок живёт всё время работы
/// приложения), а порт активной сессии может отличаться от настроенного.
typedef LocalProxyPortResolver = int? Function();

/// Значение для [HttpClient.findProxy].
///
/// Логин с паролем едут в самой строке, и dart:io ставит по ним
/// `Proxy-Authorization` на каждый запрос. Двоеточие в логине и `;` он
/// разобрал бы неверно — наши пароли из одних букв и цифр.
String localProxyDirective(
  int? httpPort, {
  String username = '',
  String password = '',
}) {
  if (httpPort == null) return 'DIRECT';
  final host = InternetAddress.loopbackIPv4.address;
  if (username.isEmpty || password.isEmpty) return 'PROXY $host:$httpPort';
  return 'PROXY $username:$password@$host:$httpPort';
}

/// Учит готовый [HttpClient] ходить через локальный HTTP-инбаунд ядра, пока
/// [resolvePort] отдаёт порт.
///
/// Dart [HttpClient.findProxy] понимает только `PROXY host:port` и `DIRECT`,
/// не `SOCKS`/`SOCKS5` — с SOCKS он кидает
/// `HttpException: Invalid proxy configuration SOCKS5 …` на Windows.
///
/// Пароль идёт в строке прокси, а не через `addProxyCredentials`: запомненный
/// пароль прокси dart:io на ответ 407 повторяет без конца (флаг «уже
/// пробовали» у них не ставится). Пароль инбаунда новый на каждое
/// подключение, а клиент подписок живёт всё время работы приложения — после
/// переподключения его запрос крутился в петле из сотен соединений в секунду,
/// и память росла до гигабайт: 3 ГБ за четверть часа на телефоне, 20 на ПК.
void configureHttpClientForLocalVpnProxy(
  HttpClient client,
  LocalProxyPortResolver resolvePort, {
  String? username,
  String? password,
}) {
  client.findProxy = (_) => localProxyDirective(
        resolvePort(),
        // Синглтон читается в момент запроса, а не сборки клиента: на Android
        // после пересоздания изолята креды восстанавливаются из нативного
        // сервиса асинхронно и могут появиться позже.
        username: username ?? Socks5Credentials().username,
        password: password ?? Socks5Credentials().password,
      );
}

/// Routes [dio] through the app's local HTTP proxy (keqrnel / xray / mihomo)
/// whenever [resolvePort] returns a port.
void configureDioForLocalVpnProxy(
  Dio dio,
  LocalProxyPortResolver resolvePort, {
  String? username,
  String? password,
}) {
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () {
      final client = HttpClient();
      configureHttpClientForLocalVpnProxy(
        client,
        resolvePort,
        username: username,
        password: password,
      );
      return client;
    },
  );
}

/// Постоянный порт: вызывающий уже решил, что идти надо в туннель.
void configureDioForLocalVpnHttpProxy(
  Dio dio, {
  required int httpPort,
  String? username,
  String? password,
}) =>
    configureDioForLocalVpnProxy(
      dio,
      () => httpPort,
      username: username,
      password: password,
    );

/// When the VPN is up, GitHub/update traffic must ride the tunnel through the
/// local HTTP inbound. That applies on Android too: the VpnService excludes the
/// app's own package from the TUN (иначе in-process xray зациклился бы), так
/// что «сокеты и так в туннеле» — неправда, прямой Dio ходит мимо VPN и
/// упирается в блокировку release-assets.githubusercontent.com.
void configureDioForActiveVpn(
  Dio dio, {
  required bool useLocalProxy,
  required int httpPort,
}) {
  if (!useLocalProxy) return;
  configureDioForLocalVpnHttpProxy(dio, httpPort: httpPort);
}

/// Резолвер для фоновых обновлений, где состояния VPN нет под рукой:
/// WorkManager-изолят на Android и таймер/резюм на десктопе.
///
/// [activeHttpPort] — порт живой сессии, записанный на диск при подключении
/// (`StorageService.getActiveLocalHttpPort`); null — VPN не подключён, идём
/// напрямую. Одной пробы порта тут мало: на 2081 может слушать другой
/// VPN-клиент (дефолты у всех похожие), и подписка с токеном ушла бы через
/// него. Проба остаётся страховкой от ядра, умершего без записи «отключено».
Future<LocalProxyPortResolver?> resolveLocalProxyForBackground(
  int? activeHttpPort,
) async {
  final port = activeHttpPort;
  if (port == null) return null;
  if (!await localHttpProxyIsListening(port)) return null;
  return () => port;
}

/// Слушает ли кто-нибудь локальный HTTP-инбаунд на [port].
///
/// Для фоновых изолятов (WorkManager на Android, таймер на десктопе): у них
/// нет ни riverpod-состояния VPN, ни ActiveLocalPorts — синглтоны живут в
/// своём изоляте. Проба дешёвая: ядро не запущено — loopback отвечает отказом
/// сразу, без таймаута.
Future<bool> localHttpProxyIsListening(
  int port, {
  Duration timeout = const Duration(milliseconds: 400),
}) async {
  try {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: timeout,
    );
    socket.destroy();
    return true;
  } on Object {
    return false;
  }
}
