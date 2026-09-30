import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/utils/local_vpn_proxy.dart';
import 'package:keqdroid/utils/socks5_credentials.dart';

/// Прокси-заглушка: отвечает на запрос с абсолютным URI (так HttpClient ходит
/// к http-адресам через прокси) и записывает первую строку запроса.
///
/// С [requireAuth] ведёт себя как локальный инбаунд с включённой
/// аутентификацией: без `Proxy-Authorization` отвечает 407.
class _RecordingProxy {
  _RecordingProxy({this.requireAuth = false});

  final bool requireAuth;
  late final HttpServer _server;
  final requestLines = <String>[];
  final authHeaders = <String?>[];

  int get port => _server.port;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      requestLines.add('${req.method} ${req.requestedUri}');
      final auth = req.headers.value(HttpHeaders.proxyAuthorizationHeader);
      authHeaders.add(auth);
      if (requireAuth && auth == null) {
        req.response
          ..statusCode = HttpStatus.proxyAuthenticationRequired
          ..headers.set(HttpHeaders.proxyAuthenticateHeader, 'Basic realm=""');
        await req.response.close();
        return;
      }
      req.response
        ..headers.contentType = ContentType.text
        ..write('proxied');
      await req.response.close();
    });
  }

  Future<void> stop() => _server.close(force: true);
}

/// Локальный инбаунд с паролем, который меняется между сессиями.
///
/// На сырых сокетах, а не на HttpServer: отказ повторяет Xray байт в байт
/// (`proxy/http/server.go`), а CONNECT надо принимать как есть. Считает
/// запросы — по их числу и видно, повторяет ли клиент отвергнутый пароль.
class _SessionProxy {
  late final ServerSocket _server;

  /// Логин и пароль, которые инбаунд принимает сейчас; null — никакие.
  (String, String)? accepted;
  final requestLines = <String>[];
  final authHeaders = <String?>[];

  int get port => _server.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((socket) {
      final head = BytesBuilder();
      socket.listen(
        (chunk) {
          head.add(chunk);
          final text = latin1.decode(head.toBytes(), allowInvalid: true);
          final end = text.indexOf('\r\n\r\n');
          if (end < 0) return;
          _answer(socket, text.substring(0, end).split('\r\n'));
        },
        onError: (_) {},
      );
    });
  }

  void _answer(Socket socket, List<String> lines) {
    final line = lines.first;
    requestLines.add(line);
    String? auth;
    for (final header in lines.skip(1)) {
      final colon = header.indexOf(':');
      if (colon > 0 &&
          header.substring(0, colon).trim().toLowerCase() ==
              'proxy-authorization') {
        auth = header.substring(colon + 1).trim();
      }
    }
    authHeaders.add(auth);
    final pair = accepted;
    final ok = pair != null &&
        auth == 'Basic ${base64.encode(utf8.encode('${pair.$1}:${pair.$2}'))}';
    if (!ok) {
      socket.add(latin1.encode(
        'HTTP/1.1 407 Proxy Authentication Required\r\n'
        'Proxy-Authenticate: Basic realm="proxy"\r\n\r\n',
      ));
    } else if (line.startsWith('CONNECT ')) {
      // Туннель открыт, но за ним никого: TLS упадёт, а нам важно только,
      // что до этой точки клиент дошёл с правильным паролем.
      socket.add(latin1.encode('HTTP/1.1 200 Connection established\r\n\r\n'));
    } else {
      socket.add(latin1.encode(
        'HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\n'
        'proxied',
      ));
    }
    unawaited(socket.flush().whenComplete(socket.destroy));
  }

  Future<void> stop() => _server.close();
}

void main() {
  group('localProxyDirective', () {
    test('null port means direct', () {
      expect(localProxyDirective(null), 'DIRECT');
    });

    test('port becomes an HTTP proxy directive (SOCKS dart:io не понимает)', () {
      expect(localProxyDirective(2081), 'PROXY 127.0.0.1:2081');
    });

    test('логин с паролем едут в самой строке', () {
      expect(
        localProxyDirective(2081, username: 'keq', password: 's3cret'),
        'PROXY keq:s3cret@127.0.0.1:2081',
      );
    });

    test('без пароля строка без логина', () {
      expect(
        localProxyDirective(2081, username: 'keq'),
        'PROXY 127.0.0.1:2081',
      );
    });
  });

  group('configureHttpClientForLocalVpnProxy', () {
    late _RecordingProxy proxy;
    // Порт, который заведомо никто не слушает: прямой запрос обязан
    // упереться в отказ соединения, а не уйти в сеть.
    late int deadPort;
    late String url;

    setUp(() async {
      proxy = _RecordingProxy();
      await proxy.start();
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      deadPort = probe.port;
      await probe.close();
      url = 'http://127.0.0.1:$deadPort/sub';
    });

    tearDown(() => proxy.stop());

    Future<String> fetch(HttpClient client) async {
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close();
      return resp.transform(utf8.decoder).join();
    }

    test('resolver с портом уводит запрос в прокси', () async {
      final client = HttpClient();
      configureHttpClientForLocalVpnProxy(client, () => proxy.port);
      addTearDown(() => client.close(force: true));

      expect(await fetch(client), 'proxied');
      expect(proxy.requestLines, ['GET $url']);
    });

    test('resolver с null оставляет запрос прямым', () async {
      final client = HttpClient();
      configureHttpClientForLocalVpnProxy(client, () => null);
      addTearDown(() => client.close(force: true));

      await expectLater(fetch(client), throwsA(isA<SocketException>()));
      expect(proxy.requestLines, isEmpty);
    });

    test('решение принимается на каждый запрос, а не при сборке клиента',
        () async {
      // Ровно тот случай, ради которого резолвер и появился: сервис подписок
      // живёт всё время работы приложения, а VPN за это время включают.
      int? port;
      final client = HttpClient();
      configureHttpClientForLocalVpnProxy(client, () => port);
      addTearDown(() => client.close(force: true));

      await expectLater(fetch(client), throwsA(isA<SocketException>()));
      expect(proxy.requestLines, isEmpty);

      port = proxy.port; // «подключили VPN»
      expect(await fetch(client), 'proxied');
      expect(proxy.requestLines, ['GET $url']);
    });
  });

  group('прокси с аутентификацией', () {
    // Креды регистрируются внутри findProxy, а не при создании клиента:
    // на Android после пересоздания изолята они приезжают из нативного
    // сервиса позже. Проверяем, что «позже» всё равно срабатывает — на этом
    // же пути живёт проверка обновлений.
    test('запрос доходит с Proxy-Authorization', () async {
      final proxy = _RecordingProxy(requireAuth: true);
      await proxy.start();
      addTearDown(proxy.stop);

      final client = HttpClient();
      configureHttpClientForLocalVpnProxy(
        client,
        () => proxy.port,
        username: 'keq',
        password: 's3cret',
      );
      addTearDown(() => client.close(force: true));

      final req = await client.getUrl(Uri.parse('http://example.test/sub'));
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();

      expect(body, 'proxied');
      expect(resp.statusCode, 200);
      // Заголовок уходит с первым же запросом, без круга через 407.
      expect(proxy.authHeaders, [
        'Basic ${base64.encode(utf8.encode('keq:s3cret'))}',
      ]);
    });

    test('креды из синглтона, появившиеся после сборки клиента, применяются',
        () async {
      // Ровно случай Android: VpnService пережил пересоздание Flutter-движка,
      // свежий изолят видит connected, а креды подтягиваются из нативного
      // сервиса асинхронно — уже после того, как клиент собран.
      final proxy = _RecordingProxy(requireAuth: true);
      await proxy.start();
      addTearDown(proxy.stop);

      addTearDown(() => Socks5Credentials().init('', ''));

      final client = HttpClient();
      configureHttpClientForLocalVpnProxy(client, () => proxy.port);
      addTearDown(() => client.close(force: true));

      // «приехали» из нативного сервиса уже после сборки клиента
      Socks5Credentials().init('late', 'creds');

      final req = await client.getUrl(Uri.parse('http://example.test/sub'));
      final resp = await req.close();

      expect(await resp.transform(utf8.decoder).join(), 'proxied');
      expect(
        proxy.authHeaders.last,
        'Basic ${base64.encode(utf8.encode('late:creds'))}',
      );
    });
  });

  group('пароль инбаунда сменился, а клиент живёт дальше', () {
    // Случай с телефона, где процесс за четверть часа дорос до 3 ГБ: клиент
    // подписок живёт всё время работы приложения, а пароль инбаунда новый на
    // каждое подключение. Запомненный dart:io пароль прокси он повторяет на
    // каждый 407 без конца — флаг «уже пробовали» у паролей прокси не
    // ставится никогда, — и каждый повтор держит в памяти весь предыдущий.
    late _SessionProxy proxy;
    late HttpClient client;

    setUp(() async {
      proxy = _SessionProxy();
      await proxy.start();
      client = HttpClient();
      configureHttpClientForLocalVpnProxy(client, () => proxy.port);
    });

    tearDown(() async {
      // Закрытый клиент рвёт и повторы, если они всё же пошли по кругу.
      client.close(force: true);
      await proxy.stop();
      Socks5Credentials().init('', '');
    });

    Future<HttpClientResponse> get(String url) async {
      final req = await client.getUrl(Uri.parse(url));
      return req.close();
    }

    String basic(String user, String pass) =>
        'Basic ${base64.encode(utf8.encode('$user:$pass'))}';

    test('после переподключения запрос идёт с новым паролем', () async {
      Socks5Credentials().init('userA', 'passA');
      proxy.accepted = ('userA', 'passA');
      final first = await get('http://example.test/sub');
      expect(await first.transform(utf8.decoder).join(), 'proxied');

      // Переподключились: у ядра новый пароль, у синглтона тоже.
      Socks5Credentials().init('userB', 'passB');
      proxy.accepted = ('userB', 'passB');
      proxy.requestLines.clear();
      proxy.authHeaders.clear();

      final second = await get('http://example.test/sub')
          .timeout(const Duration(seconds: 5));
      expect(await second.transform(utf8.decoder).join(), 'proxied');
      expect(proxy.authHeaders, [basic('userB', 'passB')]);
    });

    test('CONNECT после переподключения тоже идёт с новым паролем', () async {
      // Подписки — это https, то есть туннель CONNECT через инбаунд: именно
      // там на телефоне и крутилась петля.
      Socks5Credentials().init('userA', 'passA');
      proxy.accepted = ('userA', 'passA');
      await expectLater(get('https://example.test/sub'), throwsA(anything));

      Socks5Credentials().init('userB', 'passB');
      proxy.accepted = ('userB', 'passB');
      proxy.requestLines.clear();
      proxy.authHeaders.clear();

      // Падает на TLS за открытым туннелем — главное, что падает, а не
      // повторяет старый пароль до бесконечности.
      await expectLater(
        get('https://example.test/sub').timeout(const Duration(seconds: 5)),
        throwsA(isNot(isA<TimeoutException>())),
      );
      expect(proxy.requestLines, ['CONNECT example.test:443 HTTP/1.1']);
      expect(proxy.authHeaders, [basic('userB', 'passB')]);
    });

    test('отвергнутый пароль даёт ошибку, а не повтор по кругу', () async {
      // Пароль, который инбаунд уже не принимает (ядро перезапущено с новым,
      // а синглтон ещё не обновлён): запрос обязан упасть сразу.
      Socks5Credentials().init('stale', 'stale');
      proxy.accepted = null;

      await expectLater(
        get('https://example.test/sub').timeout(const Duration(seconds: 5)),
        throwsA(
          isA<HttpException>().having(
            (e) => e.message,
            'message',
            contains('407'),
          ),
        ),
      );
      expect(proxy.requestLines, hasLength(lessThanOrEqualTo(2)));
    });
  });

  group('resolveLocalProxyForBackground', () {
    test('нет записанного порта сессии → напрямую, без пробы', () async {
      // VPN выключен. Проба тут была бы вредна: на 2081 может слушать другой
      // VPN-клиент, и подписка с токеном ушла бы через него.
      expect(await resolveLocalProxyForBackground(null), isNull);
    });

    test('порт записан и слушается → резолвер на него', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close());

      final resolver = await resolveLocalProxyForBackground(server.port);
      expect(resolver, isNotNull);
      expect(resolver!(), server.port);
    });

    test('порт записан, но ядро умерло → напрямую', () async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();

      expect(await resolveLocalProxyForBackground(port), isNull);
    });
  });

  group('localHttpProxyIsListening', () {
    test('true, когда порт слушают', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close());
      expect(await localHttpProxyIsListening(server.port), isTrue);
    });

    test('false, когда ядро не запущено', () async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      expect(await localHttpProxyIsListening(port), isFalse);
    });
  });
}
