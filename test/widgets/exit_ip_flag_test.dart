import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/app/app.dart';
import 'package:keqdroid/l10n/app_localizations.dart';
import 'package:keqdroid/models/server_flag.dart';
import 'package:keqdroid/services/exit_ip_service.dart';
import 'package:keqdroid/shared/ui/exit_ip_flag.dart';
import 'package:keqdroid/shared/ui/server_avatar.dart';

/// Флаг выхода в чипе статуса: тот же аватар, что у серверов в списке (и той
/// же формы), адрес — только в шторке по нажатию.
void main() {
  const exit = ExitIp(ip: '45.131.212.234', countryCode: 'NL');

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ru'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: buildAppTheme(
            ColorScheme.fromSeed(seedColor: const Color(0xFF4A6DB0)),
          ),
          home: const Scaffold(
            body: Center(
              child: ExitIpFlagButton(exit: exit, flag: FlagArt('nl')),
            ),
          ),
        ),
      );

  testWidgets('на главном экране только флаг, без адреса', (tester) async {
    await pump(tester);
    await tester.pumpAndSettle();

    expect(find.byType(ServerAvatar), findsOneWidget);
    expect(find.byKey(flagArtKey), findsOneWidget);
    expect(find.text('45.131.212.234'), findsNothing);
    expect(find.bySemanticsLabel('IP, который видят сайты'), findsOneWidget);
  });

  testWidgets('нажатие открывает шторку с адресом и страной', (tester) async {
    await pump(tester);
    await tester.tap(find.byType(ExitIpFlagButton));
    await tester.pumpAndSettle();

    expect(find.text('45.131.212.234'), findsOneWidget);
    expect(find.text('NL'), findsOneWidget);
    // Флаг в шторке тот же аватар — второй экземпляр поверх первого.
    expect(find.byType(ServerAvatar), findsNWidgets(2));
  });
}
