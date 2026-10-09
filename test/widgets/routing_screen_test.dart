import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/app/app.dart';
import 'package:keqdroid/l10n/app_localizations.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/providers/providers.dart';
import 'package:keqdroid/screens/settings_tab.dart';
import 'package:keqdroid/services/rule_list_service.dart';
import 'package:keqdroid/services/vpn_engine.dart';
import 'package:keqdroid/shared/ui/expressive_button_group.dart';

import '../helpers/fake_tunnel_backend.dart';
import '../helpers/test_storage.dart';

class _FakeSettings extends SettingsNotifier {
  _FakeSettings(this._initial);
  final AppSettings _initial;

  @override
  Future<AppSettings> build() async => _initial;

  @override
  Future<void> save(AppSettings settings) async => state = AsyncData(settings);
}

/// Переподключение не поднимает туннель, а запоминает, с какими списками его
/// попросили: ровно это и видит ядро при новом подключении.
class _FakeVpn extends VpnStateNotifier {
  _FakeVpn(this._status);
  final VpnStatus _status;
  final reconnectedWith = <String>[];

  @override
  Future<VpnState> build() async => VpnState(status: _status);

  @override
  Future<void> reconnectToActiveServer() async {
    reconnectedWith.add(ref.read(settingsNotifierProvider).value!.directRules);
  }
}

/// Списки по ссылкам без сети и диска: экран только показывает их состояние.
class _FakeRuleLists extends RuleListsNotifier {
  _FakeRuleLists(this._statuses);
  final Map<String, RuleListStatus> _statuses;

  @override
  Map<String, RuleListStatus> build() => _statuses;
}

late _FakeVpn _vpn;

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  VpnStatus status = VpnStatus.disconnected,
  AppSettings settings = const AppSettings(directRules: 'vk.com'),
  Map<String, RuleListStatus> ruleLists = const {},
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);

  final storage = await buildStorageService();
  _vpn = _FakeVpn(status);
  final container = ProviderContainer(
    overrides: [
      storageProvider.overrideWithValue(storage),
      settingsNotifierProvider.overrideWith(() => _FakeSettings(settings)),
      vpnStateProvider.overrideWith(() => _vpn),
      ruleListsProvider.overrideWith(() => _FakeRuleLists(ruleLists)),
      vpnEngineProvider.overrideWithValue(
        VpnEngine.withBackend(FakeTunnelBackend()),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildAppTheme(
          ColorScheme.fromSeed(
            seedColor: const Color(0xFF6750A4),
            brightness: Brightness.dark,
          ),
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('ru'),
        // Экран берёт списки из настроек в initState — в приложении они к
        // этому времени давно загружены, здесь их надо дождаться.
        home: Consumer(
          builder: (context, ref, _) =>
              ref.watch(settingsNotifierProvider).value == null
                  ? const SizedBox()
                  : routingScreenForTest(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

AppSettings _saved(ProviderContainer c) =>
    c.read(settingsNotifierProvider).value!;

void main() {
  testWidgets('готовый список из шторки добавляется сразу, без второго шага',
      (tester) async {
    final c = await _pump(tester);

    await tester.tap(find.text('Готовые списки'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('IP России (GeoIP) напрямую'));
    await tester.pumpAndSettle();

    expect(_saved(c).directRules, contains('vk.com'));
    expect(_saved(c).directRules, contains('geoip:ru'));
    expect(find.text('Добавлено: «IP России (GeoIP) напрямую»'), findsOneWidget);
  });

  testWidgets('«всё остальное» — те же три пути и в том же порядке, что списки',
      (tester) async {
    final c = await _pump(tester);

    final buttons = tester.widget<ExpressiveConnectedButtons<String>>(
      find.byType(ExpressiveConnectedButtons<String>),
    );
    expect(buttons.segments.map((s) => s.value), [
      AppSettings.finalOutboundDirect,
      AppSettings.finalOutboundProxy,
      AppSettings.finalOutboundBlock,
    ]);
    expect(
      buttons.segments.map((s) => s.label),
      ['Напрямую', 'Через VPN', 'Блокировать'],
    );

    await tester.tap(
      find.descendant(
        of: find.byType(ExpressiveConnectedButtons<String>),
        matching: find.text('Блокировать'),
      ),
    );
    await tester.pumpAndSettle();
    expect(_saved(c).finalOutbound, AppSettings.finalOutboundBlock);
  });

  testWidgets('«Переподключить» сперва сохраняет недописанный ввод',
      (tester) async {
    await _pump(tester, status: VpnStatus.connected);

    // Сохранение ждёт паузы в наборе; кнопку жмут сразу после правки.
    await tester.enterText(find.text('vk.com'), 'vk.com, example.org');
    await tester.pump();
    await tester.tap(find.text('Переподключить'));
    await tester.pumpAndSettle();

    expect(_vpn.reconnectedWith, ['vk.com, example.org']);
  });

  testWidgets('без поднятого туннеля подсказки о переподключении нет',
      (tester) async {
    await _pump(tester);
    expect(find.text('Переподключить'), findsNothing);
  });

  group('списки по ссылкам', () {
    const ads = 'https://adguardteam.github.io/filter.txt';
    const big = 'https://big.oisd.nl/';
    const local = 'https://lists.example/hosts';

    testWidgets('под полем строка на каждую ссылку, в подписи их домены',
        (tester) async {
      await _pump(
        tester,
        settings: const AppSettings(
          directRules: 'vk.com',
          blockedRules: 'doubleclick.net, $ads\n$big\n$local',
        ),
        ruleLists: {
          ads: RuleListStatus(
            url: ads,
            domains: 82341,
            updatedAt: DateTime.now().subtract(const Duration(hours: 3)),
          ),
          big: const RuleListStatus(
            url: big,
            failure: RuleListFailure.network,
          ),
          local: RuleListStatus(
            url: local,
            domains: 120,
            updatedAt: DateTime.now().subtract(const Duration(days: 2)),
            failure: RuleListFailure.http,
            httpStatus: 404,
          ),
        },
      );

      String plain(String s) => s.replaceAll(RegExp('[\u2066-\u2069]'), '');
      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => plain(t.data ?? ''))
          .toList();

      expect(texts, contains('1 запись, 82\u00a0461 домен по ссылкам'));
      expect(
        texts,
        contains('adguardteam.github.io — 82\u00a0341 домен, обновлён 3ч назад'),
      );
      expect(
        texts,
        contains(
          'big.oisd.nl — не загрузился, повтор при следующем подключении',
        ),
      );
      // Скачанное раньше остаётся в силе — строка об этом, а не об ошибке.
      expect(
        texts,
        contains(
          'lists.example — 120 доменов, обновлён 2д назад, '
          'свежий не загрузился',
        ),
      );
    });

    testWidgets('пока ничего не скачано, ссылка — обычная запись',
        (tester) async {
      await _pump(
        tester,
        settings: const AppSettings(blockedRules: ads),
        ruleLists: {ads: const RuleListStatus(url: ads, loading: true)},
      );
      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => (t.data ?? '').replaceAll(RegExp('[\u2066-\u2069]'), ''))
          .toList();
      expect(texts, contains('1 запись'));
      expect(texts, contains('adguardteam.github.io — загружается…'));
    });
  });

  test('счётчик записей склоняется и для 21, 22, 25', () {
    final ru = lookupAppLocalizations(const Locale('ru'));
    expect(ru.settingsRoutingItemCount(0), 'пусто');
    expect(ru.settingsRoutingItemCount(1), '1 запись');
    expect(ru.settingsRoutingItemCount(21), '21 запись');
    expect(ru.settingsRoutingItemCount(22), '22 записи');
    expect(ru.settingsRoutingItemCount(25), '25 записей');
  });
}
