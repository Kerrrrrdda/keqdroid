import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/l10n/app_localizations.dart';
import 'package:keqdroid/utils/app_locale.dart';

void main() {
  const supported = AppLocalizations.supportedLocales;

  test('незнакомый язык системы даёт английский, а не первый по алфавиту', () {
    // Первым в списке стоит немецкий: так его сортирует gen-l10n.
    expect(supported.first, const Locale('de'));
    for (final device in [
      const Locale('fr'),
      const Locale('uk'),
      const Locale('C'), // Linux без локали: LANG=C
      null,
    ]) {
      expect(
        resolveAppLocale(null, device, supported),
        const Locale('en'),
        reason: '$device',
      );
    }
  });

  test('переведённый язык системы берётся по языку, без региона', () {
    expect(
      resolveAppLocale(null, const Locale('ru', 'RU'), supported),
      const Locale('ru'),
    );
    expect(
      resolveAppLocale(null, const Locale('zh', 'CN'), supported),
      const Locale('zh'),
    );
    expect(
      resolveAppLocale(null, const Locale('de', 'AT'), supported),
      const Locale('de'),
    );
  });

  test('язык из настроек важнее системного', () {
    expect(
      resolveAppLocale(const Locale('fa'), const Locale('ru'), supported),
      const Locale('fa'),
    );
  });
}
