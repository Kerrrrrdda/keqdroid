import '../tunnel/connection_mode.dart';
import '../tunnel/tunnel_state.dart';

/// Техническая начинка приложения: что за ядра стоят, какие geo-базы, что
/// происходит в текущей сессии и на чём всё это запущено.
///
/// Смысл в том, чтобы на вопрос «а какой у тебя xray?» отвечал сам клиент, а не
/// раскопки в логах: версии ядер читаются из самих бинарей ([GoBuildInfo]),
/// остальное — из настроек и состояния сессии.
class AppInternals {
  const AppInternals({
    required this.cores,
    required this.geoBases,
    required this.session,
    required this.build,
    this.processExits = const [],
  });

  final List<CoreInfo> cores;
  final List<GeoBaseInfo> geoBases;
  final SessionInfo session;
  final BuildInfo build;

  /// Прошлые смерти процесса, от свежей к старой. Пусто вне Android и до 11-й
  /// версии: раньше система их не записывает.
  final List<ProcessExit> processExits;
}

/// Чем закончилась одна из прошлых жизней процесса — запись системы
/// (`ApplicationExitInfo`), а не наша: убитый снаружи процесс сам ничего о
/// своей смерти не пишет.
class ProcessExit {
  const ProcessExit({
    required this.time,
    required this.reason,
    required this.reasonName,
    this.status = 0,
    this.importance = 0,
    this.description,
    this.vpnStatus,
    this.sdkInt,
  });

  /// Разбор ответа нативной стороны; null — запись без времени, показывать
  /// её негде.
  static ProcessExit? fromMap(Map<Object?, Object?> map, {int? sdkInt}) {
    final timestamp = map['timestamp'];
    if (timestamp is! int) return null;
    final reason = map['reason'] as int? ?? 0;
    final description = (map['description'] as String?)?.trim();
    return ProcessExit(
      time: DateTime.fromMillisecondsSinceEpoch(timestamp),
      reason: reason,
      reasonName: map['reasonName'] as String? ?? '$reason',
      status: map['status'] as int? ?? 0,
      importance: map['importance'] as int? ?? 0,
      description: description == null || description.isEmpty ? null : description,
      vpnStatus: map['vpnStatus'] as String?,
      sdkInt: sdkInt,
    );
  }

  final DateTime time;

  /// `ApplicationExitInfo.REASON_*`.
  final int reason;
  final String reasonName;

  /// Код выхода или номер сигнала — смотря по [reason].
  final int status;

  /// Насколько процесс был важен системе в момент смерти: 125 — работал
  /// сервис переднего плана, 100 — было открыто окно.
  final int importance;

  /// Слова убийцы, если он их оставил: у REASON_OTHER, например, здесь
  /// единственное объяснение, кто и за что.
  final String? description;

  /// Статус VPN, который процесс заранее отдал системе на этот случай.
  final String? vpnStatus;

  /// Версия Android: до 14-й обновление приложения записывалось той же
  /// причиной, что и ручная остановка.
  final int? sdkInt;

  bool get vpnWasOn => vpnStatus == 'connected' || vpnStatus == 'connecting';

  ProcessExitCause get cause => switch (reason) {
        1 => ProcessExitCause.self,
        3 => ProcessExitCause.memory,
        4 || 5 || 6 || 7 => ProcessExitCause.crash,
        10 when (sdkInt ?? 34) < 34 => ProcessExitCause.userOrUpdate,
        10 || 11 => ProcessExitCause.user,
        8 || 15 || 16 => ProcessExitCause.update,
        // SIGNALED сюда же: так выглядят и убийства прошивок (kill -9 от
        // своих демонов), и нехватка памяти там, где система не умеет её
        // отличать (ActivityManager.isLowMemoryKillReportSupported).
        _ => ProcessExitCause.system,
      };
}

/// Причина смерти процесса, сведённая к тому, что можно сказать человеку.
enum ProcessExitCause {
  /// Система или прошивка: SIGNALED, OTHER, FREEZER, лишний расход ресурсов.
  system,

  /// Системе не хватило памяти.
  memory,

  /// Сбой самого приложения: исключение, падение нативного кода, зависание.
  crash,

  /// Остановлено человеком: «Остановить» в настройках, смахивание из недавних.
  user,

  /// То же, но до Android 14, где обновление записывалось так же.
  userOrUpdate,

  /// Обновление приложения или смена его разрешений.
  update,

  /// Процесс завершился сам.
  self,
}

/// За что отвечает ядро. Текст подписи живёт в локализации, здесь — только роль.
enum CoreRole {
  /// Единый бинарь: и протоколы, и TUN (keqrnel на десктопе).
  core,

  /// Только протоколы и локальный SOCKS/HTTP (libxray на Android).
  proxy,

  /// Владеет TUN-устройством.
  tun,
}

/// Ядро — поставляемый с приложением Go-бинарь.
class CoreInfo {
  const CoreInfo({
    required this.name,
    required this.role,
    this.version,
    this.goVersion,
    this.path,
    this.sizeBytes,
    this.modified,
    this.engines = const {},
    this.missing = false,
  });

  /// Отсутствующий бинарь — не ошибка, а находка: панель для того и есть,
  /// чтобы показать, что ядра в сборке нет.
  const CoreInfo.missing({required this.name, required this.role})
      : version = null,
        goVersion = null,
        path = null,
        sizeBytes = null,
        modified = null,
        engines = const {},
        missing = true;

  /// Имя файла ядра: `keqrnel.exe`, `libxray.so`.
  final String name;

  final CoreRole role;

  /// Собственная версия ядра. Null — бинарь собран из рабочего дерева
  /// (`(devel)`), как keqrnel: тогда о нём говорят только [engines].
  final String? version;

  /// Версия тулчейна Go, которым собран бинарь.
  final String? goVersion;

  final String? path;
  final int? sizeBytes;
  final DateTime? modified;

  /// Движки, вкомпилированные внутрь: `xray-core` → `v1.26…`.
  /// У keqrnel это единственный источник версий xray и sing-box.
  final Map<String, String> engines;

  final bool missing;
}

/// Поставляемая база geoip/geosite.
class GeoBaseInfo {
  const GeoBaseInfo({
    required this.name,
    required this.codeCount,
    this.sizeBytes,
    this.modified,
    this.missing = false,
  });

  final String name;

  /// Сколько кодов верхнего уровня реально лежит в базе — то же число, по
  /// которому проверяются правила маршрутизации перед стартом ядра.
  final int codeCount;

  final int? sizeBytes;
  final DateTime? modified;
  final bool missing;
}

/// Что происходит прямо сейчас.
class SessionInfo {
  const SessionInfo({
    required this.status,
    required this.engine,
    required this.socksPort,
    required this.httpPort,
    this.mode,
    this.uptime,
    this.corePids = const {},
    this.elevated,
    this.clashApiPort,
  });

  final VpnStatus status;

  /// Движок сессии: `keqrnel` на десктопе, `libxray` или `libmihomo` на
  /// Android — смотря чем подключились, а не что выбрано в настройках сейчас.
  final String engine;

  /// Null — режим не применим (Android всегда TUN через VpnService).
  final ConnectionMode? mode;

  final int socksPort;
  final int httpPort;
  final Duration? uptime;

  /// Подпись процесса → pid. Пусто — сессии нет.
  final Map<String, int> corePids;

  /// Windows/Linux: запущено ли приложение с правами администратора.
  /// Null — платформа без такого понятия либо выяснить не удалось.
  final bool? elevated;

  final int? clashApiPort;

  bool get isActive =>
      status == VpnStatus.connected || status == VpnStatus.connecting;
}

/// Приложение и устройство.
class BuildInfo {
  const BuildInfo({
    required this.appVersion,
    required this.buildNumber,
    required this.packageName,
    required this.operatingSystem,
    required this.osVersion,
    required this.abi,
    required this.dartVersion,
    required this.releaseMode,
  });

  final String appVersion;
  final String buildNumber;
  final String packageName;
  final String operatingSystem;
  final String osVersion;

  /// Архитектура: `android-arm64`, `windows-x64`.
  final String abi;

  /// Только номер, без длинной строки с датой сборки SDK.
  final String dartVersion;

  final bool releaseMode;
}
