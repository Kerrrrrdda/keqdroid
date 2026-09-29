import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/app/app.dart';
import 'package:keqdroid/l10n/app_localizations.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/providers/providers.dart';
import 'package:keqdroid/screens/settings_tab.dart';
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

late _FakeVpn _vpn;

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  VpnStatus status = VpnStatus.disconnected,
  AppSettings settings = const AppSettings(directRules: 'vk.com'),
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

  test('счётчик записей склоняется и для 21, 22, 25', () {
    final ru = lookupAppLocalizations(const Locale('ru'));
    expect(ru.settingsRoutingItemCount(0), 'пусто');
    expect(ru.settingsRoutingItemCount(1), '1 запись');
    expect(ru.settingsRoutingItemCount(21), '21 запись');
    expect(ru.settingsRoutingItemCount(22), '22 записи');
    expect(ru.settingsRoutingItemCount(25), '25 записей');
  });
}
