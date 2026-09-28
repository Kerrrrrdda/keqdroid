import 'dart:convert';

import '../core/app_logger.dart';
import '../models/app_settings.dart';
import '../models/server_item.dart';
import '../models/subscription.dart';
import 'card_image_service.dart';
import 'storage_service.dart';

enum BackupSection {
  splitTunneling,
  subscriptions,
  servers,

  /// Настройки приложения — только те, что имеют смысл на другой машине.
  /// См. [SettingsBackupService.portableSettingKeys].
  appSettings,
}

class KeqdisBackup {
  final int version;
  final DateTime exportedAt;
  final Map<String, dynamic> data;

  const KeqdisBackup({
    required this.version,
    required this.exportedAt,
    required this.data,
  });

  Map<String, dynamic> toJson() => {
        'format': 'keqdis_backup',
        'version': version,
        'exportedAt': exportedAt.toIso8601String(),
        'data': data,
      };

  String toJsonString({bool pretty = true}) {
    final obj = toJson();
    return pretty
        ? const JsonEncoder.withIndent('  ').convert(obj)
        : jsonEncode(obj);
  }

  /// Файл бэкапа целиком, байтами.
  ///
  /// Всё после первого законченного объекта отбрасывается. Такой хвост
  /// оставлял экспорт на Android до того, как запись стала обрезать файл:
  /// новый бэкап поверх более длинного старого ложился в начало целиком, а за
  /// ним шёл конец прежнего. Сам бэкап в таком файле цел, терять его незачем.
  ///
  /// Режем до декодирования UTF-8: граница хвоста приходится на любой байт
  /// старого файла, в том числе на середину кириллической буквы или флага в
  /// имени сервера, и такой файл падал бы ещё на декодировании.
  static KeqdisBackup parse(List<int> bytes) {
    Object? parsed;
    try {
      parsed = jsonDecode(utf8.decode(bytes));
    } on FormatException catch (error, stackTrace) {
      final end = _leadingObjectEnd(bytes);
      if (end == null) rethrow;
      try {
        parsed = jsonDecode(utf8.decode(bytes.sublist(0, end)));
      } on FormatException {
        // Ошибка про настоящее место поломки полезнее, чем про обрезок.
        Error.throwWithStackTrace(error, stackTrace);
      }
      AppLogger.instance.warn(
        'Backup file has ${bytes.length - end} bytes after the JSON object; '
        'ignored as a leftover of an overwritten file',
      );
    }
    if (parsed is! Map<String, dynamic>) {
      throw const FormatException('Invalid JSON file');
    }
    return fromJson(parsed);
  }

  static const _quote = 0x22, _backslash = 0x5C, _braceOpen = 0x7B;
  static const _openers = {_braceOpen, 0x5B}, _closers = {0x7D, 0x5D};
  static const _whitespace = {0x20, 0x09, 0x0A, 0x0D};

  /// Длина первого объекта верхнего уровня, если файл с него начинается и он
  /// закрывается. Скобки внутри строк не считаются — в бэкапе ими полны
  /// правила маршрутизации. Считать по байтам можно: в UTF-8 байты ASCII
  /// никогда не встречаются внутри многобайтовых символов.
  static int? _leadingObjectEnd(List<int> bytes) {
    var i = 0;
    while (i < bytes.length && _whitespace.contains(bytes[i])) {
      i++;
    }
    if (i == bytes.length || bytes[i] != _braceOpen) return null;
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (; i < bytes.length; i++) {
      final b = bytes[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (b == _backslash) {
          escaped = true;
        } else if (b == _quote) {
          inString = false;
        }
      } else if (b == _quote) {
        inString = true;
      } else if (_openers.contains(b)) {
        depth++;
      } else if (_closers.contains(b)) {
        depth--;
        if (depth == 0) return i + 1;
      }
    }
    return null;
  }

  static KeqdisBackup fromJson(Map<String, dynamic> json) {
    final format = json['format'];
    if (format != 'keqdis_backup') {
      throw FormatException('Not a Keqdis backup file');
    }
    final version = (json['version'] as num?)?.toInt() ?? 0;
    if (version <= 0) {
      throw FormatException('Unsupported backup version: $version');
    }
    final exportedAt = DateTime.tryParse(json['exportedAt'] as String? ?? '');
    final data = json['data'];
    if (exportedAt == null || data is! Map<String, dynamic>) {
      throw FormatException('Invalid backup payload');
    }
    return KeqdisBackup(version: version, exportedAt: exportedAt, data: data);
  }
}

class SettingsBackupService {
  static const int currentVersion = 1;

  /// Ключи [AppSettings.toJson], которые уезжают в бэкап.
  ///
  /// Список белый, и это принципиально. Всё остальное описывает конкретную
  /// машину и её сеть — локальные порты, LAN-раздача вместе с её паролем,
  /// параметры TUN, режим подключения, десктопные флаги вроде автозапуска, —
  /// и на другой машине оно в лучшем случае бессмысленно, а в худшем ломает
  /// подключение молча. Пароль LAN здесь ещё и потому, что бэкап — обычный
  /// json-файл, которым легко поделиться.
  ///
  /// Новое поле настроек сюда само не попадает: чтобы забытое поле не осталось
  /// незамеченным, тест требует разложить каждый ключ `toJson()` либо сюда,
  /// либо в свой список машинно-зависимых.
  static const portableSettingKeys = <String>{
    // маршрутизация
    'directRules',
    'proxyRules',
    'blockedRules',
    'finalOutbound',
    // ядро и DNS
    'xrayCore',
    'vpnCore',
    'fakeIp',
    // поведение
    'autoConnectLastServer',
    'shareDeviceHwid',
    'notifySubscriptionUpdates',
    // пинг
    'pingType',
    'pingTestTarget',
    'pingTestUrlCustom',
    'pingKeepAlive',
    // внешний вид
    'darkTheme',
    'followSystemTheme',
    'themePresetId',
    'customThemeSeed',
    'customThemeVariant',
    'iconShapeId',
    'fontId',
    'amoledBlack',
    'serversTwoColumns',
    'serverIconThemeColors',
    'uiScale',
    'hapticFeedback',
    'showTrafficStats',
    'showConnectionTime',
    'showTrafficSplit',
    'waveLatencyColor',
    'showSpeedInNotification',
    'showUptimeInNotification',
    // язык
    'appLanguageCode',
  };

  static Future<KeqdisBackup> buildBackup(
    StorageService storage, {
    required Set<BackupSection> sections,
  }) async {
    final data = <String, dynamic>{};

    if (sections.contains(BackupSection.splitTunneling)) {
      data['splitTunneling'] = {
        'excludePackages': storage.getExcludePackages(),
        'includePackages': storage.getIncludePackages(),
      };
    }

    if (sections.contains(BackupSection.subscriptions)) {
      final subs = await storage.getSubscriptions();
      data['subscriptions'] = subs.map((s) => s.toJson()).toList();
      // Тема, вуаль и состав карточки — обычные поля подписки и уезжают строкой
      // выше. Своя картинка — файл в каталоге приложения, и без её байтов на
      // новой машине от оформления остаётся только несуществующий id.
      final images = await CardImageService.exportForThemes(
        subs.map((s) => s.cardThemeId),
      );
      if (images.isNotEmpty) data['cardImages'] = images;
    }

    if (sections.contains(BackupSection.servers)) {
      final servers = await storage.getServers();
      data['servers'] = {
        'activeServerId': storage.getActiveServerId(),
        'items': servers.map((s) => s.toJson()).toList(),
      };
    }

    if (sections.contains(BackupSection.appSettings)) {
      final json = (await storage.getSettings()).toJson();
      data['appSettings'] = {
        for (final key in portableSettingKeys)
          if (json.containsKey(key)) key: json[key],
      };
    }

    return KeqdisBackup(
      version: currentVersion,
      exportedAt: DateTime.now(),
      data: data,
    );
  }

  static Set<BackupSection> detectSections(KeqdisBackup backup) {
    final s = <BackupSection>{};
    if (backup.data['splitTunneling'] is Map) s.add(BackupSection.splitTunneling);
    if (backup.data['subscriptions'] is List) s.add(BackupSection.subscriptions);
    if (backup.data['servers'] is Map) s.add(BackupSection.servers);
    if (backup.data['appSettings'] is Map) s.add(BackupSection.appSettings);
    return s;
  }

  static Future<void> applyBackup(
    StorageService storage, {
    required KeqdisBackup backup,
    required Set<BackupSection> sections,
  }) async {
    if (sections.contains(BackupSection.splitTunneling)) {
      final raw = backup.data['splitTunneling'];
      if (raw is! Map) throw FormatException('Invalid splitTunneling section');
      final exclude = (raw['excludePackages'] as List?)?.whereType<String>().toList() ?? <String>[];
      final include = (raw['includePackages'] as List?)?.whereType<String>().toList() ?? <String>[];
      await storage.setExcludePackages(exclude);
      await storage.setIncludePackages(include);
    }

    if (sections.contains(BackupSection.subscriptions)) {
      final raw = backup.data['subscriptions'];
      if (raw is! List) throw FormatException('Invalid subscriptions section');
      final subs = raw
          .whereType<Map>()
          .map((e) => Subscription.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      // Картинки раскладываем до подписок: иначе первый кадр списка рисуется по
      // теме, файла которой ещё нет на диске, и карточка мигает обычной.
      final images = backup.data['cardImages'];
      if (images is Map) {
        await CardImageService.importAll({
          for (final e in images.entries)
            if (e.key is String && e.value is String)
              e.key as String: e.value as String,
        });
      }
      await storage.saveSubscriptions(subs);
    }

    if (sections.contains(BackupSection.servers)) {
      final raw = backup.data['servers'];
      if (raw is! Map) throw FormatException('Invalid servers section');
      final items = raw['items'];
      if (items is! List) throw FormatException('Invalid servers.items section');

      final servers = items
          .whereType<Map>()
          .map((e) => ServerItem.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      await storage.saveServers(servers);

      final activeId = raw['activeServerId'] as String?;
      // Only set active server if it exists after import.
      if (activeId != null && servers.any((s) => s.id == activeId)) {
        await storage.setActiveServerId(activeId);
      } else if (activeId == null) {
        await storage.setActiveServerId(null);
      }
    }

    if (sections.contains(BackupSection.appSettings)) {
      final raw = backup.data['appSettings'];
      if (raw is! Map) throw FormatException('Invalid appSettings section');
      // Поверх нынешних, а не вместо них: в бэкапе лежит только переносимая
      // часть, и остальное (порты, LAN, TUN, режим подключения) обязано остаться
      // от этой машины.
      final merged = (await storage.getSettings()).toJson();
      for (final key in portableSettingKeys) {
        if (raw.containsKey(key)) merged[key] = raw[key];
      }
      // Копии до 26.09.2026 хранят fake-ip под старым именем, когда он был
      // настройкой одного mihomo.
      if (!raw.containsKey('fakeIp') && raw.containsKey('mihomoFakeIp')) {
        merged['fakeIp'] = raw['mihomoFakeIp'];
      }
      await storage.saveSettings(AppSettings.fromJson(merged));
    }
  }
}
