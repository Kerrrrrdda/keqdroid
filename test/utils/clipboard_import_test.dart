import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/l10n/app_localizations.dart';
import 'package:keqdroid/models/subscription.dart';
import 'package:keqdroid/providers/providers.dart';
import 'package:keqdroid/utils/clipboard_import.dart';

/// Подписки без сети: настоящий `add` сразу качал бы её содержимое.
class _FakeSubs extends SubscriptionsNotifier {
  final added = <Subscription>[];

  @override
  Future<List<Subscription>> build() async => const [];

  @override
  Future<void> add(Subscription sub) async => added.add(sub);
}

/// Серверы без хранилища: `_load()` настоящего полез бы в SharedPreferences.
class _FakeServers extends ServersNotifier {
  final added = <String>[];

  @override
  ServersState build() => ServersState();

  @override
  Future<void> addManual(String rawConfig) async => added.add(rawConfig);
}

/// Кнопка «Вставить ссылку(и)» с пустого экрана серверов, без самого экрана.
Future<(_FakeSubs, _FakeServers)> _pasteFromClipboard(
  WidgetTester tester,
  String clipboard,
) async {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async => call.method == 'Clipboard.getData'
        ? <String, dynamic>{'text': clipboard}
        : null,
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));

  final subs = _FakeSubs();
  final servers = _FakeServers();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        subscriptionsProvider.overrideWith(() => subs),
        serversProvider.overrideWith(() => servers),
      ],
      child: MaterialApp(
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => pasteLinksFromClipboard(context, ref),
              child: const Text('paste'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('paste'));
  await tester.pumpAndSettle();
  return (subs, servers);
}

void main() {
  testWidgets('ссылка подписки из буфера становится подпиской', (tester) async {
    final (subs, servers) =
        await _pasteFromClipboard(tester, 'https://sub.example/api/token');

    expect(subs.added.single.url, 'https://sub.example/api/token');
    expect(subs.added.single.name, 'sub.example');
    expect(subs.added.single.nameIsAuto, isTrue);
    expect(servers.added, isEmpty);
    expect(find.text('Подписка добавлена: sub.example'), findsOneWidget);
  });

  testWidgets('ссылка сервера из буфера становится сервером', (tester) async {
    const vless = 'vless://uuid@de.example.com:443?security=tls&type=tcp#DE';
    final (subs, servers) = await _pasteFromClipboard(tester, vless);

    expect(subs.added, isEmpty);
    expect(servers.added, [vless]);
    expect(find.text('Добавлено серверов: 1 из 1'), findsOneWidget);
  });
}
