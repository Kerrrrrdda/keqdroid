import 'package:flutter/material.dart';

import '../models/app_settings.dart';

/// подпись языка для настроек.
String appLanguageLabel(AppSettings settings, {required String systemLabel}) {
  return switch (settings.appLanguageCode) {
    'en' => 'English',
    'ru' => 'Русский',
    'de' => 'Deutsch',
    'zh' => '中文',
    'fa' => 'فارسی',
    _ => systemLabel,
  };
}

/// Язык интерфейса: выбранный в настройках, иначе системный, если он
/// переведён, иначе английский. Первый из [supported] брать нельзя: gen-l10n
/// сортирует их по алфавиту, и незнакомый язык системы (французский,
/// украинский, `C` на Linux без локали) превращался в немецкий.
Locale resolveAppLocale(
  Locale? chosen,
  Locale? device,
  Iterable<Locale> supported,
) {
  if (chosen != null) {
    return supported.contains(chosen) ? chosen : const Locale('en');
  }
  if (device != null) {
    for (final l in supported) {
      if (l.languageCode == device.languageCode) return l;
    }
  }
  return const Locale('en');
}

Locale? localeFromSettings(AppSettings settings) {
  return switch (settings.appLanguageCode) {
    'en' => const Locale('en'),
    'ru' => const Locale('ru'),
    'de' => const Locale('de'),
    'zh' => const Locale('zh'),
    'fa' => const Locale('fa'),
    _ => null,
  };
}
