part of 'providers.dart';

/// Что делать с состоянием из натива, пока идёт наша попытка подключения.
enum ConnectInFlightAction {
  /// Не трогать состояние: сообщение ничего не говорит об исходе попытки.
  ignore,

  /// Применить, попытка продолжается.
  apply,

  /// Применить и считать попытку завершённой.
  applyAndFinish,
}

/// Правило отсечки для [VpnStateNotifier].
///
/// Ключевой случай — `disconnected` до старта сессии. Между тапом и запуском
/// сервиса стрим и полутрасекундный поллинг успевают доложить «отключено»,
/// потому что сервис ещё не поднят. Принять этот ответ за исход попытки —
/// значит погасить UI на полпути: connecting → disconnected → connected.
/// Особенно заметно на первом подключении, когда сервис холодный.
ConnectInFlightAction connectInFlightAction(
  VpnStatus status, {
  required bool awaitingSessionStart,
}) {
  if (awaitingSessionStart && status == VpnStatus.disconnected) {
    return ConnectInFlightAction.ignore;
  }
  return switch (status) {
    VpnStatus.connected ||
    VpnStatus.disconnected =>
      ConnectInFlightAction.applyAndFinish,
    VpnStatus.error => ConnectInFlightAction.apply,
    _ => ConnectInFlightAction.ignore,
  };
}

class VpnStateNotifier extends AsyncNotifier<VpnState> {
  StreamSubscription<VpnState>? _sub;
  bool _connectInFlight = false;
  // Окно от тапа до фактического старта сессии. Всё это время нативный сервис
  // ещё не поднят и честно отвечает `disconnected` — принимать этот ответ за
  // исход нашей попытки нельзя.
  bool _awaitingSessionStart = false;
  bool _serverSwitchInProgress = false;
  // Пользователь отменил попытку подключения (тап по кругу в connecting) —
  // connect-in-flight сворачивается в disconnected вместо error/connected.
  bool _cancelRequested = false;
  // Сигналит _waitForDisconnected при приходе события disconnected из стрима —
  // вместо опроса state с фиксированными задержками.
  Completer<void>? _disconnectWaiter;
  Timer? _androidPollTimer;

  /// Сторож автовыбора: сколько байт туннель пропустил к прошлому тику. Байты
  /// и есть главное доказательство жизни — пока они идут, в сеть сторож не
  /// ходит вовсе.
  Timer? _autoSelectTimer;
  Timer? _autoSelectListenTimer;
  int _autoSelectSeenReceived = 0;
  int _autoSelectSeenSent = 0;
  int? _autoSelectSeenFailures;
  SilenceStreak _autoSelectSilence = const SilenceStreak();
  ({int down, int up})? _autoSelectCounters;
  final _autoSelectSwitches = <DateTime>[];
  DateTime? _autoSelectQuietUntil;
  bool _autoSelectBusy = false;

  /// Прошлая секунда прослушки ещё не вернулась: на десктопе это запрос к
  /// ядру, и медленное ядро получало бы их внахлёст, по одному в секунду.
  bool _autoSelectListening = false;

  /// Плановая проверка ([AutoSelectWatchdog.recheckEvery]) и сколько байт
  /// туннель пропустил к прошлой: не сдвинулось — телефон лежит, и проверять
  /// нечего.
  Timer? _autoSelectRecheckTimer;
  int? _autoSelectRecheckSeenBytes;
  AppLifecycleListener? _androidLifecycle;

  void _applyNativeState(VpnState s) {
    _restoreSocksCredentialsIfNeeded(s);
    _syncMihomoApiSession(s);
    _persistActiveLocalHttpPort(s.status);
    if (_serverSwitchInProgress && s.status == VpnStatus.error) return;
    if (_connectInFlight) {
      // Реальный неуспех попытки ловит _awaitNativeConnectOutcome, поэтому
      // отсечка ничего не теряет.
      switch (connectInFlightAction(
        s.status,
        awaitingSessionStart: _awaitingSessionStart,
      )) {
        case ConnectInFlightAction.ignore:
          break;
        case ConnectInFlightAction.apply:
          state = AsyncData(s);
        case ConnectInFlightAction.applyAndFinish:
          state = AsyncData(s);
          _connectInFlight = false;
      }
      return;
    }
    final current = state.value;
    if (current != null &&
        current.status == s.status &&
        current.telemetryEquals(s)) {
      return;
    }
    state = AsyncData(s);
  }

  /// Порт HTTP-инбаунда живой сессии и пароль к нему — на диск, для фоновых
  /// изолятов.
  ///
  /// Они обновляют подписки, не видя ни riverpod-состояния, ни ActiveLocalPorts
  /// (синглтон живёт в своём изоляте), а идти мимо туннеля им нельзя: пакет
  /// приложения исключён из TUN. Пробы порта тут мало — на 2081 может слушать
  /// другой VPN-клиент, и подписка с токеном ушла бы через него.
  void _persistActiveLocalHttpPort(VpnStatus status) {
    final storage = ref.read(storageProvider);
    if (status != VpnStatus.connected) {
      // Сброс идёт без единого await: иначе запись подключения, застрявшая на
      // чтении настроек, воскресила бы порт уже после отключения.
      if (storage.getActiveLocalHttpPort() != null) {
        unawaited(storage.setActiveLocalHttpPort(null));
      }
      return;
    }
    unawaited(_writeActiveLocalHttpPort(storage));
  }

  Future<void> _writeActiveLocalHttpPort(StorageService storage) async {
    // Сессионный порт ставит только десктоп (LocalPortResolver); на Android
    // подмены нет — там правда в настройках, и читать её надо через
    // getSettings: кэш может быть ещё холодным, и на диск уехал бы дефолтный
    // порт вместо настроенного.
    final port =
        ActiveLocalPorts().httpPort ?? (await storage.getSettings()).httpPort;
    if (!ref.mounted) return;
    // За время чтения статус мог смениться — не воскрешаем порт после отключения
    if (state.value?.status != VpnStatus.connected) return;
    // _applyNativeState зовётся и на каждый тик телеметрии — пишем только
    // смену. Пароль сверяем тоже: после переподключения порт прежний, а пароль
    // новый, и на Android он ещё и приезжает из сервиса позже порта.
    final creds = Socks5Credentials();
    final stored = storage.getActiveLocalHttpCredentials();
    if (storage.getActiveLocalHttpPort() == port &&
        stored.username == creds.username &&
        stored.password == creds.password) {
      return;
    }
    await storage.setActiveLocalHttpPort(
      port,
      username: creds.username,
      password: creds.password,
    );
  }

  bool _credsRestoreInFlight = false;

  /// VpnService на Android переживает пересоздание Flutter-движка, а синглтон
  /// Socks5Credentials живёт в Dart-изоляте: свежий изолят видит connected, но
  /// ходит в запароленный локальный http-инбаунд без Proxy-Authorization и
  /// получает 407 (проверка обновлений, рефреш подписок). Подтягиваем креды
  /// работающей сессии из нативного сервиса. Connect-flow перезапишет их при
  /// следующем подключении через Socks5Credentials().init.
  void _restoreSocksCredentialsIfNeeded(VpnState s) {
    if (!Platform.isAndroid) return;
    if (s.status != VpnStatus.connected) return;
    if (Socks5Credentials().isInitialized) return;
    if (_credsRestoreInFlight) return;
    _credsRestoreInFlight = true;
    unawaited(() async {
      try {
        final creds =
            await ref.read(vpnEngineProvider).fetchActiveSocksCredentials();
        if (creds != null) {
          Socks5Credentials().init(creds.username, creds.password);
          AppLogger.instance.info(
            'SOCKS5 credentials restored from the running VPN service',
          );
        }
      } finally {
        _credsRestoreInFlight = false;
      }
    }());
  }

  bool _mihomoApiRestoreInFlight = false;

  /// Держит [MihomoApiSession] в согласии с тем, что реально происходит в
  /// нативном сервисе.
  ///
  /// Два случая, когда синглтон пуст, а сессия жива: пересоздание
  /// Flutter-движка и реконнект из плитки (там ядро поднимает сервис, connect-
  /// flow в Dart не выполняется вовсе). В обоих натив достаёт пару из файла
  /// конфига, который исполняет ядро.
  ///
  /// Обратная сторона — отключение: в мёртвый порт экран «Соединения» стучался
  /// бы по три секунды на каждый опрос, показывая «Core API unreachable»
  /// вместо честного «сессии нет».
  void _syncMihomoApiSession(VpnState s) {
    final api = MihomoApiSession();
    // Зачистка — на всех платформах: пара переживает сессию, а по ней
    // «Соединения» решают, к какому диалекту API обращаться.
    if (s.status == VpnStatus.disconnected || s.status == VpnStatus.error) {
      api.clear();
      return;
    }
    // Восстановление — только на Android: это единственное место, где сессия
    // ядра переживает Dart-изолят (плитка, пересоздание движка).
    if (!Platform.isAndroid) return;
    if (s.status != VpnStatus.connected) return;
    if (api.isActive || _mihomoApiRestoreInFlight) return;
    _mihomoApiRestoreInFlight = true;
    unawaited(() async {
      try {
        final restored = await VpnNativeBridge.getMihomoApi();
        if (restored != null) {
          api.restore(port: restored.port, secret: restored.secret);
          AppLogger.instance.info(
            'mihomo API restored from the running VPN service',
          );
        }
      } finally {
        _mihomoApiRestoreInFlight = false;
      }
    }());
  }

  void _startAndroidPolling() {
    if (!Platform.isAndroid) return;
    _androidPollTimer?.cancel();
    _androidPollTimer = Timer.periodic(
      const Duration(milliseconds: 1500),
      (_) => unawaited(syncFromNative()),
    );
  }

  void _stopAndroidPolling() {
    _androidPollTimer?.cancel();
    _androidPollTimer = null;
  }

  void _onAndroidResumed() {
    if (!Platform.isAndroid) return;
    ref.read(vpnEngineProvider).refreshStateStream();
    unawaited(syncFromNative());
    _startAndroidPolling();
  }

  @override
  Future<VpnState> build() async {
    final engine = ref.read(vpnEngineProvider);
    unawaited(_sub?.cancel());
    _sub = engine.stateStream.listen((s) {
      if (s.status == VpnStatus.disconnected) {
        final waiter = _disconnectWaiter;
        if (waiter != null && !waiter.isCompleted) waiter.complete();
      }
      _applyNativeState(s);
    });
    _autoSelectTimer?.cancel();
    _autoSelectTimer = Timer.periodic(
      AutoSelectWatchdog.probeEvery,
      (_) => unawaited(_autoSelectTick()),
    );
    _autoSelectListenTimer?.cancel();
    _autoSelectListenTimer = Timer.periodic(
      AutoSelectWatchdog.listenEvery,
      (_) => unawaited(_autoSelectListenOnce()),
    );
    _autoSelectRecheckTimer?.cancel();
    _autoSelectRecheckTimer = Timer.periodic(
      AutoSelectWatchdog.recheckEvery,
      (_) => unawaited(_autoSelectRecheck()),
    );
    ref.onDispose(() {
      _autoSelectTimer?.cancel();
      _autoSelectListenTimer?.cancel();
      _autoSelectRecheckTimer?.cancel();
      _sub?.cancel();
      _stopAndroidPolling();
      _androidLifecycle?.dispose();
      _androidLifecycle = null;
    });

    if (Platform.isAndroid) {
      _androidLifecycle?.dispose();
      _androidLifecycle = AppLifecycleListener(
        onResume: _onAndroidResumed,
        onPause: _stopAndroidPolling,
        onHide: _stopAndroidPolling,
      );
      _onAndroidResumed();
    }

    try {
      return await engine.getCurrentState();
    } catch (_) {
      return VpnState.disconnected;
    }
  }

  /// Подтягивает фактическое состояние из нативного сервиса (Android VpnService).
  /// Нужно при возврате в приложение и когда VPN переключали из шторки/плитки QS.
  Future<void> syncFromNative() async {
    try {
      final s = await ref.read(vpnEngineProvider).getCurrentState();
      _applyNativeState(s);
    } catch (e, st) {
      AppLogger.instance.debug(
        'syncFromNative failed',
        error: e,
        stackTrace: st,
      );
    }
  }

  Future<VpnState> _awaitNativeConnectOutcome(VpnEngine engine) async {
    for (var i = 0; i < 150; i++) {
      await Future.delayed(const Duration(milliseconds: 300));
      if (_cancelRequested) {
        return const VpnState(status: VpnStatus.disconnected);
      }
      final s = await engine.getCurrentState();
      if (s.status == VpnStatus.connected ||
          s.status == VpnStatus.error ||
          s.status == VpnStatus.disconnected) {
        return s;
      }
    }
    return engine.getCurrentState();
  }

  /// Домены из списков по ссылкам — из того, что уже лежит на диске: сети
  /// подключение не ждёт, свежесть держит [ruleListsProvider]. Нечитаемый
  /// кэш — не повод не подключаться: тогда едем без списков.
  Future<RuleListDomains> _cachedRuleLists(AppSettings settings) async {
    try {
      final lists = await ref.read(ruleListServiceProvider).domainsFor(settings);
      if (!lists.isEmpty) {
        AppLogger.instance.info(
          'Rule lists: block ${lists.blocked.length}, '
          'direct ${lists.direct.length}, proxy ${lists.proxy.length} domains',
        );
      }
      return lists;
    } catch (e, st) {
      AppLogger.instance.warn(
        'Rule lists unreadable, connecting without them',
        error: e,
        stackTrace: st,
      );
      return RuleListDomains.none;
    }
  }

  /// Builds alternate Android VPN configs for the selected physical networks.
  ///
  /// Android gives the app one VpnService/TUN, so network routing is implemented
  /// by restarting the same core with a different config when Wi-Fi/cellular
  /// changes. We deliberately require the alternate server to resolve to the
  /// same core backend as the primary session: switching the native engine in
  /// the middle of a live TUN session is a separate lifecycle problem.
  Future<Map<String, Map<String, String>>> _buildNetworkRouteConfigs({
    required ServerItem activeServer,
    required List<ServerItem> servers,
    required AppSettings settings,
    required VpnBackend primaryBackend,
    required ConnectionMode connectionMode,
    required AppRoutingMode routingMode,
    required bool localInboundsNoAuth,
    required int? mihomoApiPort,
    required String mihomoApiSecret,
    required RuleListDomains ruleLists,
  }) async {
    if (!Platform.isAndroid || connectionMode != ConnectionMode.tun) {
      return const {};
    }

    final byId = {for (final server in servers) server.id: server};
    final selected = <String, String>{
      'wifi': settings.wifiServerId,
      'cellular': settings.cellularServerId,
    };
    final result = <String, Map<String, String>>{};

    for (final entry in selected.entries) {
      final id = entry.value.trim();
      if (id.isEmpty || id == activeServer.id) continue;

      final server = byId[id];
      if (server == null) {
        AppLogger.instance.warn(
          'Network routing: saved ${entry.key} server $id no longer exists; '
          'using the active server for this network.',
        );
        continue;
      }

      try {
        final choice = resolveVpnBackend(
          config: server.config,
          preference: settings.vpnCore,
          mihomoAvailable: mihomoShipsHere,
        );
        if (choice.backend != primaryBackend) {
          AppLogger.instance.warn(
            'Network routing: skipping ${entry.key} server '
            '"${server.displayName}" because it needs '
            '${choice.backend.wireValue}, while the active session uses '
            '${primaryBackend.wireValue}. Choose a compatible server/core.',
          );
          continue;
        }

        final serverIp =
            await _resolveFirstAddress(server.address) ?? server.address;
        final String config;
        if (primaryBackend == VpnBackend.mihomo) {
          config = MihomoConfigGen.generate(
            server.config,
            settings,
            socksPort: settings.localPort,
            httpPort: settings.httpPort,
            resolvedServerIp: serverIp,
            localInboundsNoAuth: localInboundsNoAuth,
            apiPort: mihomoApiPort,
            apiSecret: mihomoApiSecret,
            tun: const MihomoTunOptions(
              fromFileDescriptor: true,
              stack: TunSettings.stackGvisor,
              autoRoute: false,
            ),
            routingMode: routingMode,
            // On Android process matching is handled outside the core.
            managedProcessNames: const [],
            appProcessName: '',
            ruleLists: ruleLists,
          );
        } else {
          final geoIndex =
              server.protocol == 'custom' ? await GeoAssetService.index() : null;
          config = ConfigGeneratorV2.generateConfig(
            server.config,
            ruleLists.expand(settings),
            resolvedServerIp: serverIp,
            localInboundsNoAuth: localInboundsNoAuth,
            geoIndex: geoIndex,
            nativeTunInbound: true,
          );
        }

        result[entry.key] = {
          'config': config,
          'backend': primaryBackend.wireValue,
          'serverName': server.displayName,
        };
      } catch (e, st) {
        // A bad alternate must not prevent the primary server from connecting.
        AppLogger.instance.warn(
          'Network routing: could not generate ${entry.key} config for '
          '"${server.displayName}"; the active server will be used instead.',
          error: e,
          stackTrace: st,
        );
      }
    }
    return result;
  }

  /// Правка настроек, сделанная по ходу подключения, ложится на сохранённые
  /// настройки, а не на `settings` из connect(): там списки уже в виде для
  /// ядра — со сложенными структурными правилами и без неизвестных geo-кодов.
  /// На диске этот вид навсегда приклеил бы правила к полям: выключенное
  /// правило продолжало бы работать, а включённое дописывалось бы ещё раз.
  Future<void> _saveDuringConnect(
    AppSettings Function(AppSettings saved) change,
  ) async {
    final saved = await ref.read(settingsNotifierProvider.future);
    await ref.read(settingsNotifierProvider.notifier).save(change(saved));
  }

  Future<void> connect({bool autostartTunFallback = false}) async {
    if (_connectInFlight) {
      AppLogger.instance.debug('VPN connect() ignored: connect already in progress');
      return;
    }

    final server = ref.read(serversProvider).activeServer;
    if (server == null) {
      state = AsyncData(VpnState(
        status: VpnStatus.error,
        errorMessage: 'No active server selected',
      ));
      return;
    }

    _connectInFlight = true;
    _cancelRequested = false;
    _awaitingSessionStart = true;

    try {
      await ref.read(serversProvider.notifier).setActive(server);

      final engine = ref.read(vpnEngineProvider);

      // Плитка QS / уведомление могли уже поднять VPN, пока Flutter готовил конфиг.
      final native = await engine.getCurrentState();
      if (native.status == VpnStatus.connected) {
        state = AsyncData(native);
        return;
      }
      if (native.status == VpnStatus.connecting) {
        // Сервис уже поднимается (плитка QS / уведомление) — «отключено» из
        // стрима с этого момента говорит о нашей же сессии, отсечку снимаем.
        _awaitingSessionStart = false;
        state = AsyncData(native);
        final settled = await _awaitNativeConnectOutcome(engine);
        state = AsyncData(settled);
        if (_cancelRequested ||
            settled.status == VpnStatus.connected ||
            settled.status == VpnStatus.error) {
          return;
        }
      } else {
        state = const AsyncData(VpnState(status: VpnStatus.connecting));
      }
      // Структурированные правила (RoutingRule) складываем в текстовые списки
      // настроек — так они попадают в оба генератора конфига без правок в них.
      // Затем выкидываем geoip:/geosite:-коды, которых нет в поставляемых базах:
      // xray на неизвестном коде не игнорирует правило, а падает на разборе
      // всего конфига, и подключение умирает с «SOCKS port not ready».
      var settings = await GeoAssetService.sanitizeRules(
        applyRoutingRules(
          await ref.read(storageProvider).getSettings(),
          await ref.read(storageProvider).getRules(),
        ),
      );
      // Свои DNS-адреса, которых ядро не исполнит, генератор выбрасывает молча
      // (иначе они не «не сработают», а не дадут ядру подняться). Пользователю
      // это видно только по тому, что его DNS «не применился» — говорим прямо.
      if (settings.xrayCore.dnsUseCustom) {
        final dropped =
            XrayCoreSettings.xrayDnsServers(settings.xrayCore.dnsServers)
                .dropped;
        if (dropped.isNotEmpty) {
          AppLogger.instance.warn(
            'Custom DNS: ${dropped.length} address(es) dropped — the core '
            'cannot run them: ${dropped.join(', ')}. Supported: plain ip[:port], '
            'https+local://, https://, h2c://, tcp://, quic+local://, '
            'localhost, fakedns.',
          );
        }
      }
      final ruleLists = await _cachedRuleLists(settings);

      final split = ref.read(splitTunnelingProvider);
      final excludePkgs = split.excludePackages.toList();
      final includePkgs = split.includePackages.toList();
      final routingMode = routingModeFromSplit(
        includePackages: split.includePackages,
        excludePackages: split.excludePackages,
      );
      // На Linux имена сюда не передавались вовсе — ограничение осталось от
      // времени, когда десктопом был один Windows, — и сплит в TUN там не
      // исполнялся. Android отдаёт сплит VpnService, имена ядру не нужны.
      final processNames = (Platform.isWindows || Platform.isLinux)
          ? processNamesForSplit(
              includePackages: split.includePackages,
              excludePackages: split.excludePackages,
            )
          : const <String>[];

      var connectionMode = TunnelSessionBuilder.resolveMode(settings);

      // Разрешение на VPN — только если сессия и правда поднимет интерфейс.
      // В режиме «прокси» на Android establish() не вызывается, и системный
      // диалог был бы просьбой о праве, которым не воспользуешься.
      if (Platform.isAndroid && connectionMode != ConnectionMode.proxy) {
        final permitted = await engine.requestVpnPermission();
        if (!permitted) throw const VpnPermissionDeniedException();
      }
      if ((Platform.isWindows || Platform.isLinux) &&
          connectionMode == ConnectionMode.proxy &&
          routingMode != AppRoutingMode.allProxy) {
        // Не «сплит не сработал», а «сессия идёт как весь-трафик»: без туннеля
        // ядро не знает процесса-владельца соединения, а оставленный от сплита
        // финал (`onlySelected` → DIRECT) отправил бы мимо прокси всё.
        AppLogger.instance.warn(
          'Split tunneling rules are ignored in Proxy mode on desktop: without '
          'a tunnel the core cannot tell which process a connection belongs '
          'to. The session runs as "all traffic" instead — switch to TUN mode '
          'to apply per-process rules.',
        );
      }
      if (Platform.isWindows && connectionMode == ConnectionMode.tun) {
        final elevated = await engine.requestVpnPermission();
        if (!elevated) {
          if (autostartTunFallback) {
            connectionMode = ConnectionMode.proxy;
            AppLogger.instance.warn(
              'Autostart: TUN requires admin rights, falling back to Proxy',
            );
            // Персистим фактический режим, чтобы sidebar/tray показывали Proxy,
            // а не TUN. Иначе UI остаётся в TUN, и повторный выбор TUN не
            // срабатывает (next == current), вынуждая делать proxy→tun вручную.
            await _saveDuringConnect(
              (saved) => saved.copyWith(
                connectionMode: ConnectionMode.proxy.storageValue,
              ),
            );
          } else {
            AppLogger.instance.warn(
              'TUN mode: app is not elevated. sing-box may fail to create routes.',
            );
          }
        }
      }

      // Локальные порты — это пожелание, а не факт. 2080 держит сосед (второй
      // клиент, наше же осиротевшее ядро, локальный сервер), а на Windows целые
      // диапазоны изымает Hyper-V/WSL: слушателя нет, `netstat` пуст, бинд
      // запрещён (WSAEACCES). Раньше любой из этих случаев заканчивался отказом
      // подключаться — снаружи «прокси/TUN не работает», а чинить надо руками и
      // в другом месте. Теперь порт подбирается рабочий; расхождение с
      // настройкой идёт в лог, а сами настройки не переписываются: на диск по
      // ходу подключения уходят только точечные правки (_saveDuringConnect).
      if (Platform.isWindows || Platform.isLinux) {
        final portPlan = await LocalPortResolver.resolve(settings);
        for (final change in portPlan.changes) {
          AppLogger.instance.warn(change.describe());
        }
        settings = portPlan.applyTo(settings);
        ActiveLocalPorts().set(
          socksPort: portPlan.socksPort,
          httpPort: portPlan.httpPort,
        );
      }

      // 1. забираем SOCKS5-креды у нативного сервиса
      final creds = await engine.fetchSocksCredentials();
      // В режиме прокси креды вписывают руками в чужое приложение, поэтому там
      // нужны постоянные, а не сессионные: нативные генерируются заново на
      // каждое подключение, и настройка в стороннем приложении протухала бы
      // после первого же реконнекта.
      if (Platform.isAndroid &&
          connectionMode == ConnectionMode.proxy &&
          settings.proxyModeAuth) {
        var user = settings.proxyModeUser;
        var pass = settings.proxyModePass;
        if (user.isEmpty || pass.isEmpty) {
          user = randomProxyToken(12);
          pass = randomProxyToken(20);
          settings = settings.copyWith(proxyModeUser: user, proxyModePass: pass);
          await _saveDuringConnect(
            (saved) => saved.copyWith(proxyModeUser: user, proxyModePass: pass),
          );
        }
        Socks5Credentials().init(user, pass);
      } else {
        Socks5Credentials().init(creds.username, creds.password);
      }

      // 2. резолвим домен сервера заранее, чтобы direct-правило роутинга
      //    шло по IP, а не по домену (важно когда DNS сам идёт через прокси)
      final serverIp =
          await _resolveFirstAddress(server.address) ?? server.address;

      // Desktop system/Firefox proxy config — Windows wininet, GNOME gsettings,
      // Firefox user.js — has no field for SOCKS/HTTP credentials, so password
      // auth on the localhost inbounds makes browsers prompt endlessly. Use
      // noauth on the loopback inbounds in desktop proxy mode (safe: they bind
      // to 127.0.0.1 only).
      //
      // На Android в режиме прокси — та же причина, и она там жёстче.
      // Пароль к локальному SOCKS придуман для тех, кто
      // ходит в ядро в режиме VPN, и креды ему передаются в обход человека. В
      // режиме прокси в ядро ходит чужое приложение, а системному полю «прокси»
      // у Wi-Fi негде взять логин с паролем — там только адрес и порт. Оставь
      // мы auth, режим не работал бы вовсе: ядро отвечает `invalid username or
      // password` на каждое соединение.
      // На десктопе auth в прокси-режиме невозможен всегда (системный прокси и
      // Firefox кред не шлют), на Android — настройка.
      final proxyModeNoAuth = connectionMode == ConnectionMode.proxy &&
          (!Platform.isAndroid || !settings.proxyModeAuth);

      // Ядро выбирает формат сервера, а настройка — только там, где формат
      // берут оба (обычная ссылка). Готовый конфиг исполняет то ядро, на языке
      // которого он написан: xray-json — xray, clash-yaml — mihomo. Несовпадение
      // с выбором пользователя больше не молчит: раньше это выглядело как
      // «настройка не работает» (в списке ядер mihomo, в сессии libxray).
      final choice = resolveVpnBackend(
        config: server.config,
        preference: settings.vpnCore,
        mihomoAvailable: mihomoShipsHere,
      );
      if (choice.skip != null) {
        AppLogger.instance.warn(
          'Core preference "${settings.vpnCore}" is not used for this server: '
          '${vpnCoreSkipLogReason(choice.skip!)}. Running it on '
          '${choice.backend.wireValue}.',
        );
      }

      final vpnBackend = choice.backend;
      final mihomoPicked = vpnBackend == VpnBackend.mihomo;

      // Координаты API ядра нужны до генерации: они едут внутрь конфига.
      // У xray-пути аналога нет — там «Соединения» читают access-лог.
      final mihomoApi = MihomoApiSession();
      if (mihomoPicked) {
        await mihomoApi.renew();
      } else {
        mihomoApi.clear();
      }

      // Туннель принадлежит самому mihomo: адаптер, маршруты и перехват DNS —
      // его, а не sing-box'а. Различие платформ ровно одно: на
      // десктопе ядро создаёт устройство само, на Android получает готовый
      // дескриптор от VpnService (и потому не трогает ни адреса, ни маршруты).
      final MihomoTunOptions? mihomoTun;
      if (!mihomoPicked) {
        mihomoTun = null;
      } else if (Platform.isAndroid) {
        mihomoTun = const MihomoTunOptions(
          fromFileDescriptor: true,
          // Стек не спрашиваем: `TunSettings` — десктопная настройка, а gvisor
          // держит весь TCP/IP внутри процесса ядра, что на Android
          // единственный рабочий вариант без root.
          stack: TunSettings.stackGvisor,
          autoRoute: false,
        );
      } else if (connectionMode == ConnectionMode.tun) {
        mihomoTun = MihomoTunOptions(
          device: kTunInterfaceName,
          stack: settings.tun.stack,
          mtu: settings.tun.mtu,
          autoRoute: settings.tun.autoRoute,
          strictRoute:
              settings.tun.strictRouteEnabled(windows: Platform.isWindows),
        );
      } else {
        mihomoTun = null;
      }

      final mihomoConfig = mihomoPicked
          ? MihomoConfigGen.generate(
              server.config,
              settings,
              socksPort: settings.localPort,
              // HTTP-инбаунд нужен и на Android, а не только на десктопе: под
              // туннель ядро читает само, но приложение ходит в него
              // через локальный HTTP-прокси — `Dart HttpClient` не умеет SOCKS
              // вовсе, а свой пакет исключён из TUN. Без этого порта проверка
              // обновлений на mihomo падала с «connection refused»: xray
              // http-in поднимает всегда (config_gen), mihomo — не поднимал.
              httpPort: settings.httpPort,
              resolvedServerIp: serverIp,
              localInboundsNoAuth: proxyModeNoAuth,
              apiPort: mihomoApi.port,
              apiSecret: mihomoApi.secret,
              tun: mihomoTun,
              routingMode: routingMode,
              managedProcessNames: switch (routingMode) {
                AppRoutingMode.onlySelected ||
                AppRoutingMode.allExceptSelected =>
                  processNames,
                AppRoutingMode.allProxy => const <String>[],
              },
              appProcessName: Platform.isAndroid
                  ? ''
                  : p.basename(Platform.resolvedExecutable),
              ruleLists: ruleLists,
            )
          : null;

      // Готовый конфиг несёт свои geo-правила: неизвестный ядру код уронил бы
      // разбор целиком (для списков настроек это уже сделал
      // GeoAssetService.sanitizeRules выше).
      final customGeoIndex =
          server.protocol == 'custom' ? await GeoAssetService.index() : null;
      // Чистка молчит, а выброшенное авторское правило меняет смысл конфига:
      // его трафик проваливается в наш `final`, и с «остальной трафик = блок»
      // перестаёт ходить вовсе. Снаружи это «приложение блокирует то, что
      // провайдер пускает через прокси» — называем причину вслух.
      if (server.protocol == 'custom') {
        // Правила автора, привязанные к его инбаундам, после подмены инбаундов
        // не сработают ни разу. Перехват DNS мы делаем за него сами, всё
        // остальное — молча мёртвый код в конфиге, и снаружи это «правила
        // провайдера не работают».
        final parsed = CustomXrayConfig.tryParse(server.config);
        final dead = parsed == null
            ? (rules: 0, tags: const <String>[])
            : previewDeadInboundRules(
                parsed.json,
                ConfigGeneratorV2.appInboundTags,
              );
        if (dead.rules > 0) {
          AppLogger.instance.warn(
            'Provider config: ${dead.rules} routing rule(s) are bound to '
            'inbound tags this app does not create '
            '(${dead.tags.toSet().join(', ')}). The app replaces the config '
            'inbounds with its own — those rules will never match, and their '
            'traffic follows "unmatched traffic" in Settings → Routing.',
          );
        }
      }
      if (customGeoIndex != null && !customGeoIndex.isEmpty) {
        final parsed = CustomXrayConfig.tryParse(server.config);
        final lost = parsed == null
            ? (tokens: const <String>[], removedRules: 0)
            : previewUnknownGeo(parsed.json, customGeoIndex);
        if (lost.removedRules > 0) {
          final blocked =
              settings.finalOutbound == AppSettings.finalOutboundBlock;
          AppLogger.instance.warn(
            'Provider config: ${lost.removedRules} routing rule(s) were '
            'dropped — their geo codes are not in the bundled databases: '
            '${lost.tokens.toSet().join(', ')}. The core exits on an unknown '
            'code, so the rules cannot be kept. Their traffic now falls '
            'through to "unmatched traffic" in Settings → Routing'
            '${blocked ? ', which is set to BLOCK — that traffic will not '
                'connect at all. Set it to Proxy or Bypass, or replace the '
                'codes in the config.' : '.'}',
          );
        }
      }

      // У mihomo свой конфиг, xray-генератор для него не запускаем.
      // Туннель отдаём самому ядру только там, где ему есть что отдавать:
      // на Android, в режиме VPN и на самом xray. В режиме «прокси»
      // интерфейса нет вовсе, у mihomo туннель свой.
      final nativeTun = Platform.isAndroid &&
          connectionMode == ConnectionMode.tun &&
          !mihomoPicked;

      // xray и sing-box получают скачанные домены прямо в полях; у mihomo они
      // уже в его конфиге набором (см. MihomoConfigGen.buildRuleListProviders).
      final listedSettings =
          mihomoPicked ? settings : ruleLists.expand(settings);

      final xrayConfig = mihomoPicked
          ? ''
          : ConfigGeneratorV2.generateConfig(
              server.config,
              listedSettings,
              resolvedServerIp: serverIp,
              localInboundsNoAuth: proxyModeNoAuth,
              geoIndex: customGeoIndex,
              nativeTunInbound: nativeTun,
            );

      // Pre-generate alternate configs while all server/rule/core choices are
      // still known. Android's native service can then switch between files
      // without depending on the Flutter activity staying alive.
      final networkConfigs = await _buildNetworkRouteConfigs(
        activeServer: server,
        servers: ref.read(serversProvider).servers,
        settings: settings,
        primaryBackend: vpnBackend,
        connectionMode: connectionMode,
        routingMode: routingMode,
        localInboundsNoAuth: proxyModeNoAuth,
        mihomoApiPort: mihomoApi.port,
        mihomoApiSecret: mihomoApi.secret,
        ruleLists: ruleLists,
      );

      // Забирать ли IPv6 в туннель. Спрашиваем машину, а не только настройку:
      // IPv6-адрес на TUN-интерфейсе там, где IPv6 в системе выключен, роняет
      // sing-box на старте («set ipv6 dns: Access is denied»), то есть чинил бы
      // утечку ценой неработающего TUN. См. [TunSettings.blockIpv6Leak].
      final hostHasIpv6 = connectionMode == ConnectionMode.tun &&
              (Platform.isWindows || Platform.isLinux) &&
              settings.tun.blockIpv6Leak &&
              !mihomoPicked
          ? await hostHasGlobalIpv6(excludeInterfaceName: kTunInterfaceName)
          : false;
      // Молчаливого отката быть не должно: у mihomo туннель свой, и наш
      // sing-box-инбаунд с его IPv6-адресом в этой схеме не участвует вовсе.
      if (mihomoPicked &&
          connectionMode == ConnectionMode.tun &&
          settings.tun.blockIpv6Leak &&
          (Platform.isWindows || Platform.isLinux) &&
          await hostHasGlobalIpv6(excludeInterfaceName: kTunInterfaceName)) {
        AppLogger.instance.warn(
          'This machine has global IPv6, but the tunnel here belongs to the '
          'mihomo core, which keeps its own IPv6 handling — the TUN option '
          '"keep IPv6 inside the tunnel" covers the xray/keqrnel core only. '
          'IPv6 traffic can therefore bypass the tunnel; switch the core to '
          'xray in Settings → About if that matters.',
        );
      }

      // Свои DNS в десктопном TUN исполняет sing-box, а он держит ровно один
      // резолвер (см. [SingBoxTunConfigGen.ignoredCustomDnsServers]). На xray
      // тот же список опрашивается по очереди, поэтому «у меня три сервера, а
      // работает первый» — не поломка, но и не то, о чём можно молчать.
      if (!mihomoPicked &&
          !Platform.isAndroid &&
          connectionMode == ConnectionMode.tun) {
        final ignored = SingBoxTunConfigGen.ignoredCustomDnsServers(settings);
        if (ignored.isNotEmpty) {
          AppLogger.instance.warn(
            'Custom DNS: in TUN mode the core runs a single resolver, so only '
            'the first usable address is in effect. Not used: '
            '${ignored.join(', ')}.',
          );
        }
      }

      final session = TunnelSessionBuilder.build(
        settings: listedSettings,
        xrayConfig: xrayConfig,
        vpnBackend: vpnBackend,
        mihomoConfig: mihomoConfig,
        resolvedServerIp: serverIp,
        socksUsername: creds.username,
        socksPassword: creds.password,
        excludePackages: excludePkgs,
        includePackages: includePkgs,
        excludeProcesses: routingMode == AppRoutingMode.allExceptSelected
            ? processNames
            : const [],
        includeProcesses: routingMode == AppRoutingMode.onlySelected
            ? processNames
            : const [],
        networkConfigs: networkConfigs,
        routingMode: routingMode,
        serverName: server.displayName,
        modeOverride: connectionMode,
        hostHasIpv6: hostHasIpv6,
      );
      await engine.startSession(session);
      _awaitingSessionStart = false;

      if (_cancelRequested) {
        // Отмена пришла, пока сессия поднималась — гасим её и выходим тихо.
        try {
          await engine.stopVpn();
        } catch (_) {}
        state = const AsyncData(VpnState(status: VpnStatus.disconnected));
        return;
      }

      var sessionState = await engine.getCurrentState();
      if (sessionState.status == VpnStatus.connecting) {
        sessionState = await _awaitNativeConnectOutcome(engine);
      }
      if (_cancelRequested) {
        state = const AsyncData(VpnState(status: VpnStatus.disconnected));
        return;
      }
      if (sessionState.status == VpnStatus.connected) {
        state = AsyncData(sessionState);
      } else if (sessionState.status == VpnStatus.error) {
        // Присваиваем явно: во время смены сервера _applyNativeState дропает
        // error-эмиты из стрима (_serverSwitchInProgress), а на десктопе нет
        // поллинга — без этого UI навсегда застревал в «подключается».
        state = AsyncData(sessionState);
      } else {
        state = AsyncData(VpnState(
          status: VpnStatus.connected,
          activeMode: sessionState.activeMode,
        ));
      }
    } catch (e, st) {
      if (_cancelRequested) {
        // Ошибка спровоцирована самой отменой (ядро убито стопом) —
        // это не сбой подключения, показываем спокойный «отключён».
        state = const AsyncData(VpnState(status: VpnStatus.disconnected));
        return;
      }
      AppLogger.instance.error(
        'VPN connect failed in VpnStateNotifier.connect()',
        error: e,
        stackTrace: st,
      );
      state = AsyncData(VpnState(
        status: VpnStatus.error,
        errorMessage: e.toString(),
      ));
      Error.throwWithStackTrace(e, st);
    } finally {
      _connectInFlight = false;
      _awaitingSessionStart = false;
      // Ветки connect() присваивают state напрямую, мимо _applyNativeState —
      // порт сессии на диск кладём здесь, каким бы ни был исход.
      _persistActiveLocalHttpPort(
        state.value?.status ?? VpnStatus.disconnected,
      );
    }
  }

  /// Отмена идущей попытки подключения (тап по кругу в состоянии connecting):
  /// гасим поднимающуюся сессию, connect-in-flight завершится как disconnected.
  /// Если connect уже не в полёте — обычный disconnect.
  Future<void> cancelConnect() async {
    if (!_connectInFlight) {
      await disconnect();
      return;
    }
    _cancelRequested = true;
    // Отмена — «отключено» из стрима снова значимо, даже если сессия ещё не
    // успела стартовать.
    _awaitingSessionStart = false;
    state = const AsyncData(VpnState(status: VpnStatus.disconnecting));
    try {
      await ref.read(vpnEngineProvider).stopVpn();
    } catch (e, st) {
      AppLogger.instance.warn(
        'cancelConnect: stopVpn failed',
        error: e,
        stackTrace: st,
      );
    }
  }

  Future<void> disconnect() async {
    state = const AsyncData(VpnState(status: VpnStatus.disconnecting));
    // Порты сессии больше ничего не слушает — апдейтер обязан вернуться к
    // настройке, а не стучаться в подменённый порт умершего ядра.
    ActiveLocalPorts().clear();
    _persistActiveLocalHttpPort(VpnStatus.disconnecting);
    try {
      await ref.read(vpnEngineProvider).stopVpn();
    } catch (e, st) {
      AppLogger.instance.error(
        'VPN disconnect failed in VpnStateNotifier.disconnect()',
        error: e,
        stackTrace: st,
      );
      state = AsyncData(VpnState(
        status: VpnStatus.error,
        errorMessage: e.toString(),
      ));
      Error.throwWithStackTrace(e, st);
    }
  }

  /// Сервер и подписка, за которыми сейчас следит автовыбор, или null.
  ({ServerItem server, String subId})? _autoSelectTarget() {
    if (state.value?.status != VpnStatus.connected) return null;
    final server = ref.read(serversProvider).activeServer;
    final subId = server?.subscriptionId;
    if (server == null || subId == null) return null;
    final subs = ref.read(subscriptionsProvider).value ?? const <Subscription>[];
    final owner = subs.where((s) => s.id == subId).firstOrNull;
    if (owner == null || !owner.autoSelect) return null;
    return (server: server, subId: subId);
  }

  /// Адрес замера — тот же, что у пинга серверов в списке.
  Future<String> _autoSelectTestUrl() async {
    final settings = await ref.read(storageProvider).getSettings();
    final custom = settings.pingTestUrlCustom.trim();
    return settings.pingTestTarget == 'custom' && custom.isNotEmpty
        ? custom
        : kDefaultPingTestUrl;
  }

  /// Запускает замер текущего сервера и его соседей — судью автовыбора.
  ///
  /// Меряет тем же url-пингом, что и список серверов, только с коротким
  /// таймаутом: вопрос не «насколько быстр», а «жив ли прямо сейчас». Ядро
  /// замера идёт мимо туннеля, поэтому ответ не зависит ни от правил
  /// роутинга, ни от того, что творится в живой сессии. Результаты копятся по
  /// мере прихода — решать можно, не дожидаясь таймаута мёртвого сервера — и
  /// в конце ложатся в список: мёртвый сервер краснеет там же, где его видно.
  _AutoSelectMeasure _autoSelectStartMeasure(
    ServerItem current,
    String subId, {
    int limit = AutoSelectWatchdog.candidateLimit,
    Set<String> include = const {},
  }) {
    final measure = _AutoSelectMeasure(current.id);
    final servers = AutoServerSelect.candidatesToMeasure(
      ref.read(serversProvider).servers,
      subscriptionId: subId,
      current: current,
      limit: limit,
      include: include,
    );
    ({String id, bool success, int? latencyMs}) entry(PingResult r) =>
        (id: r.serverId, success: r.success, latencyMs: r.latencyMs);
    measure.done = () async {
      try {
        final settings = await ref.read(storageProvider).getSettings();
        final results = await PingService.pingUrlBatch(
          servers,
          settings,
          testUrl: await _autoSelectTestUrl(),
          timeoutSeconds: AutoSelectWatchdog.judgeTimeoutSeconds,
          onResult: (r) => measure.add(entry(r)),
        );
        for (final r in results) {
          measure.results[r.serverId] = entry(r);
        }
        unawaited(
          ref.read(serversProvider.notifier).updatePingResults({
            for (final r in results)
              r.serverId: (
                pingMs: r.success ? r.latencyMs : null,
                lastPingType: PingService.pingTypeToStored(r.pingType),
              ),
          }),
        );
      } catch (e, st) {
        AppLogger.instance.debug(
          'Auto select measure failed',
          error: e,
          stackTrace: st,
        );
      } finally {
        measure.finish();
      }
    }();
    return measure;
  }

  /// Тихая прослушка: раз в секунду, без сети.
  ///
  /// Два сигнала. Первый — «ушло, но ничего не пришло»: скорости за последнюю
  /// секунду сервис считает сам, и на мёртвом сервере приложения продолжают
  /// слать, а в ответ не приходит ни байта (см. [SilenceStreak]). Второй —
  /// отказ дозвона в логе ядра: он ловит сервер, который отвечает сбросом
  /// соединения, — сброс тоже пришедший байт, и тишины тогда нет. Сам по себе
  /// ни один сигнал сервер не меняет: он только зовёт судью
  /// ([_autoSelectDecide]).
  ///
  /// Замер начинается, только когда судью уже позвали. Начатый раньше, на
  /// первой тихой секунде, он сам ломал счёт: трафик сервис считает по всему
  /// приложению, ответы живых соседей выглядели ответом сервера, и тишина не
  /// набиралась — на Vless живой тест так и не дождался переезда.
  Future<void> _autoSelectListenOnce() async {
    if (_autoSelectListening) return;
    _autoSelectListening = true;
    try {
      await _autoSelectListen();
    } finally {
      _autoSelectListening = false;
    }
  }

  Future<void> _autoSelectListen() async {
    if (_autoSelectBusy) return;
    final target = _autoSelectTarget();
    if (target == null) {
      _autoSelectSeenFailures = null;
      _autoSelectSilence = const SilenceStreak();
      _autoSelectCounters = null;
      return;
    }
    final quietUntil = _autoSelectQuietUntil;
    if (quietUntil != null && DateTime.now().isBefore(quietUntil)) return;

    final second = await _autoSelectSecond();
    if (second != null) {
      _autoSelectSilence = _autoSelectSilence.next(
        sent: second.sent,
        received: second.received,
      );
    }

    // На Android отказы считает нативный читатель лога ядра, на десктопе —
    // бэкенд, который читает вывод ядра сам.
    final failures = Platform.isAndroid
        ? await VpnNativeBridge.dialFailures()
        : CoreDialFailures.count;
    var newFailures = 0;
    if (failures != null) {
      final previous = _autoSelectSeenFailures;
      _autoSelectSeenFailures = failures;
      // Первое чтение — только точка отсчёта: счётчик копится с запуска
      // процесса, и старые отказы к этой сессии отношения не имеют.
      if (previous != null) newFailures = failures - previous;
    }

    final stalled = AutoSelectWatchdog.trafficStalled(
      _autoSelectSilence.silent,
      desktop: !Platform.isAndroid,
    );
    if (!stalled && !AutoSelectWatchdog.dialFailuresSuggestDeadServer(newFailures)) {
      return;
    }
    await _autoSelectDecide(
      target.server,
      _autoSelectStartMeasure(target.server, target.subId),
      reason: stalled
          ? 'nothing came back for ${_autoSelectSilence.silent} s'
          : '$newFailures failed dial(s) in the core log',
    );
  }

  /// Сколько ушло и пришло за последнюю секунду; null — пока не знаем.
  ///
  /// На Android скорости считает сервис. На десктопе состояние сессии их не
  /// несёт вовсе, а экранный опрос счётчиков стоит, пока окно в трее, —
  /// поэтому сторож читает кумулятивные счётчики ядра сам и вычитает прошлое
  /// показание. Первое чтение и переподключение — только точка отсчёта.
  Future<({int sent, int received})?> _autoSelectSecond() async {
    final engine = ref.read(vpnEngineProvider);
    if (Platform.isAndroid) {
      final now = await engine.getCurrentState();
      return (sent: now.uploadSpeed ?? 0, received: now.downloadSpeed ?? 0);
    }
    final counters = await engine.sessionTrafficCounters();
    final previous = _autoSelectCounters;
    _autoSelectCounters = counters;
    if (counters == null || previous == null) return null;
    if (counters.up < previous.up || counters.down < previous.down) return null;
    return (sent: counters.up - previous.up, received: counters.down - previous.down);
  }

  /// Страховочный тик: ловит соединения, которые повисли молча.
  ///
  /// Раз в [AutoSelectWatchdog.probeEvery] смотрим, пришёл ли через туннель
  /// хоть байт, и зовём судью, только если за это время что-то уходило, а не
  /// пришло ничего. Пришёл, а не прошёл: в мёртвый туннель приложения шлют
  /// исправно.
  Future<void> _autoSelectTick() async {
    if (_autoSelectBusy) return;
    final target = _autoSelectTarget();
    if (target == null) return;
    final received = state.value?.totalDownload ?? 0;
    final sent = state.value?.totalUpload ?? 0;
    // Счётчики обнуляются с каждой сессией. Меньше прошлого — значит, это уже
    // другая сессия, и сравнивать нечего: раньше такой сброс читался как
    // «ничего не пришло» и будил судью наугад.
    final newSession =
        received < _autoSelectSeenReceived || sent < _autoSelectSeenSent;
    final moved = newSession || received > _autoSelectSeenReceived;
    final wentOut = !newSession && sent > _autoSelectSeenSent;
    _autoSelectSeenReceived = received;
    _autoSelectSeenSent = sent;
    final quietUntil = _autoSelectQuietUntil;
    if (quietUntil != null && DateTime.now().isBefore(quietUntil)) return;
    if (!AutoSelectWatchdog.shouldProbe(
      connected: true,
      autoSelectOn: true,
      trafficMoved: moved,
      trafficSent: wentOut,
    )) {
      return;
    }
    await _autoSelectDecide(
      target.server,
      _autoSelectStartMeasure(target.server, target.subId),
      reason: 'nothing received for ${AutoSelectWatchdog.probeEvery.inSeconds} s',
    );
  }

  /// Судья: решает по замеру и, если надо, переезжает.
  ///
  /// Уйти с сервера можно только если он сам не ответил на свежий замер, и
  /// только на тот, кто ответил. Не ответил никто — остаёмся: это сеть или
  /// всё сразу, и переезд ничего не даст. Решение пересматривается с каждым
  /// пришедшим результатом: отказ текущего и первый живой сосед — и переезд,
  /// не дожидаясь, пока остальные упрутся в таймаут. Пока судья решает, прослушка стоит ([_autoSelectBusy]): трафик его
  /// замера она приняла бы за ответ сервера.
  /// Переезд идёт тем же путём, которым сервер меняет человек, и не чаще
  /// [AutoSelectWatchdog.maxSwitchesPerWindow] раз за окно.
  Future<void> _autoSelectDecide(
    ServerItem server,
    _AutoSelectMeasure measure, {
    required String reason,
  }) async {
    if (_autoSelectBusy) return;
    _autoSelectBusy = true;
    var switched = false;
    // Причина и вердикт — в лог: на десктопе он пишется в файл, и живой тест
    // без них превращается в гадание, звался ли судья вообще.
    AppLogger.instance.info('Auto select: checking ${server.displayName} — $reason');
    try {
      var verdict = AutoServerSelect.judge(
        currentId: server.id,
        results: measure.results.values,
        batchComplete: measure.complete,
      );
      while (!verdict.decided) {
        await measure.changed;
        verdict = AutoServerSelect.judge(
          currentId: server.id,
          results: measure.results.values,
          batchComplete: measure.complete,
        );
      }
      final nextId = verdict.nextId;
      if (nextId == null) {
        final answered = measure.results[server.id]?.success == true;
        AppLogger.instance.info(
          answered
              ? 'Auto select: ${server.displayName} answered, staying'
              : 'Auto select: nobody answered, staying on ${server.displayName}',
        );
        return;
      }
      if (state.value?.status != VpnStatus.connected) return;
      // Пока шёл замер, человек мог выбрать сервер сам — его выбор главнее.
      if (ref.read(serversProvider).activeServer?.id != server.id) return;

      final now = DateTime.now();
      _autoSelectSwitches.removeWhere(
        (t) => now.difference(t) >= AutoSelectWatchdog.switchWindow,
      );
      if (!AutoSelectWatchdog.switchAllowed(_autoSelectSwitches, now)) {
        AppLogger.instance.warn(
          'Auto select: ${AutoSelectWatchdog.maxSwitchesPerWindow} switches '
          'in ${AutoSelectWatchdog.switchWindow.inMinutes} min already, '
          'leaving ${server.displayName} alone for now',
        );
        return;
      }
      final next = ref
          .read(serversProvider)
          .servers
          .where((s) => s.id == nextId)
          .firstOrNull;
      if (next == null) return;
      AppLogger.instance.info(
        'Auto select: ${server.displayName} did not answer, '
        '${next.displayName} did — switching',
      );
      final subId = server.subscriptionId;
      if (subId != null) {
        await AutoSelectHomeStore.save(
          AutoSelectHome.afterFailover(
            await AutoSelectHomeStore.load(),
            subscriptionId: subId,
            fromId: server.id,
            toId: next.id,
          ),
        );
      }
      switched = true;
      _autoSelectSwitches.add(now);
      await ref.read(serversProvider.notifier).setActive(next);
      await reconnectToActiveServer();
    } catch (e, st) {
      AppLogger.instance.debug(
        'Auto select decision failed',
        error: e,
        stackTrace: st,
      );
    } finally {
      // Отсчёт заново: переподключение само даёт отказы и тихие секунды, и
      // принять их за новую смерть значило бы пойти по кругу.
      _autoSelectSeenFailures = null;
      _autoSelectSilence = const SilenceStreak();
      _autoSelectCounters = null;
      _autoSelectQuietUntil = DateTime.now().add(
        switched
            ? AutoSelectWatchdog.quietAfterSwitch
            : AutoSelectWatchdog.quietAfterCheck,
      );
      _autoSelectBusy = false;
    }
  }

  /// Плановая проверка раз в [AutoSelectWatchdog.recheckEvery].
  ///
  /// Мерит текущий сервер, свой (если ждём его, см. [AutoSelectHome]) и пару
  /// лучших соседей. Текущий не ответил — решает судья, как при тревоге.
  /// Ответил — смотрим на свой: отвечает [AutoSelectHome.returnAfter] раз
  /// подряд — возвращаемся.
  Future<void> _autoSelectRecheck() async {
    if (_autoSelectBusy) return;
    final target = _autoSelectTarget();
    var home = await AutoSelectHomeStore.load();
    if (target == null) {
      // VPN выключен — свой сервер ждёт следующего подключения, а «Авто»,
      // погасшее в его подписке, значит, что сервер выбирает уже человек.
      final subs = ref.read(subscriptionsProvider).value ?? const <Subscription>[];
      if (home != null &&
          !subs.any((s) => s.id == home!.subscriptionId && s.autoSelect)) {
        await AutoSelectHomeStore.save(null);
      }
      _autoSelectRecheckSeenBytes = null;
      return;
    }
    if (home != null) {
      final waiting = home.stillWaiting(
        activeId: target.server.id,
        autoSubscriptionId: target.subId,
        homeExists: ref
            .read(serversProvider)
            .servers
            .any((s) => s.id == home!.homeId),
      );
      if (waiting == null) await AutoSelectHomeStore.save(null);
      home = waiting;
    }

    // Байты не сдвинулись с прошлой проверки — телефон лежит, и ядро замера
    // раз в пять минут на всю ночь было бы тратой батареи. Счётчика нет вовсе
    // (бывает на десктопе) — проверяем без этого условия.
    final bytes = await _autoSelectTotalBytes();
    final seen = _autoSelectRecheckSeenBytes;
    _autoSelectRecheckSeenBytes = bytes;
    if (bytes != null && (seen == null || bytes <= seen)) return;

    final quietUntil = _autoSelectQuietUntil;
    if (quietUntil != null && DateTime.now().isBefore(quietUntil)) return;

    final homeId = home?.homeId;
    final measure = _autoSelectStartMeasure(
      target.server,
      target.subId,
      limit: AutoSelectWatchdog.recheckLimit,
      include: {?homeId},
    );
    await _autoSelectDecide(target.server, measure, reason: 'scheduled check');
    if (home == null) return;

    _autoSelectBusy = true;
    try {
      // Судья решает по первым ответам, а свой сервер мог ответить позже.
      await measure.done;
      if (state.value?.status != VpnStatus.connected) return;
      // Судья увёз на другой сервер или человек выбрал сам — тогда свой
      // сервер уже записан заново или сброшен, и решать тут нечего.
      if (ref.read(serversProvider).activeServer?.id != target.server.id) return;
      home = home.afterCheck(
        homeAnswered: measure.results[home.homeId]?.success == true,
      );
      if (!home.shouldReturn) {
        await AutoSelectHomeStore.save(home);
        return;
      }
    } finally {
      _autoSelectBusy = false;
    }
    await _autoSelectReturnHome(target.server, home);
  }

  /// Переезд обратно на свой сервер — с теми же предохранителями, что у
  /// аварийного: не чаще [AutoSelectWatchdog.maxSwitchesPerWindow] раз за окно
  /// и с паузой после.
  Future<void> _autoSelectReturnHome(
    ServerItem from,
    AutoSelectHome home,
  ) async {
    final back = ref
        .read(serversProvider)
        .servers
        .where((s) => s.id == home.homeId)
        .firstOrNull;
    if (back == null) {
      await AutoSelectHomeStore.save(null);
      return;
    }
    final now = DateTime.now();
    _autoSelectSwitches.removeWhere(
      (t) => now.difference(t) >= AutoSelectWatchdog.switchWindow,
    );
    if (!AutoSelectWatchdog.switchAllowed(_autoSelectSwitches, now)) {
      // Окно забито переездами — попробуем на следующей проверке.
      await AutoSelectHomeStore.save(home);
      return;
    }
    AppLogger.instance.info(
      'Auto select: ${back.displayName} answered ${home.aliveStreak} checks '
      'in a row — returning from ${from.displayName}',
    );
    await AutoSelectHomeStore.save(null);
    _autoSelectBusy = true;
    _autoSelectSwitches.add(now);
    try {
      await ref.read(serversProvider.notifier).setActive(back);
      await reconnectToActiveServer();
    } catch (e, st) {
      AppLogger.instance.debug(
        'Auto select return failed',
        error: e,
        stackTrace: st,
      );
    } finally {
      _autoSelectSeenFailures = null;
      _autoSelectSilence = const SilenceStreak();
      _autoSelectCounters = null;
      _autoSelectQuietUntil = DateTime.now().add(
        AutoSelectWatchdog.quietAfterSwitch,
      );
      _autoSelectBusy = false;
    }
  }

  /// Сколько байт сессия пропустила в обе стороны; null — счётчика нет.
  Future<int?> _autoSelectTotalBytes() async {
    final engine = ref.read(vpnEngineProvider);
    try {
      if (Platform.isAndroid) {
        final now = await engine.getCurrentState();
        final down = now.totalDownload;
        final up = now.totalUpload;
        if (down == null && up == null) return null;
        return (down ?? 0) + (up ?? 0);
      }
      final counters = await engine.sessionTrafficCounters();
      return counters == null ? null : counters.down + counters.up;
    } catch (_) {
      return null;
    }
  }

  /// переподключение к текущему activeServer (смена сервера на активном VPN)
  Future<void> reconnectToActiveServer() async {
    if (_serverSwitchInProgress || _connectInFlight) return;

    final status = state.value?.status;
    if (status != VpnStatus.connected && status != VpnStatus.connecting) {
      await connect();
      return;
    }

    _serverSwitchInProgress = true;
    ref.read(vpnServerSwitchInProgressProvider.notifier).set(true);
    try {
      state = const AsyncData(VpnState(status: VpnStatus.disconnecting));
      await ref.read(vpnEngineProvider).stopVpn();
      await _waitForDisconnected();
      await connect();
    } finally {
      _serverSwitchInProgress = false;
      ref.read(vpnServerSwitchInProgressProvider.notifier).set(false);
    }
  }

  Future<void> _waitForDisconnected() async {
    final status = state.value?.status;
    // Ждём только если ещё не disconnected. Чтение state и регистрация
    // _disconnectWaiter синхронны (между ними нет await), поэтому событие из
    // стрима не может проскользнуть в зазоре — гонки нет (Dart однопоточен).
    if (status != null && status != VpnStatus.disconnected) {
      final waiter = _disconnectWaiter = Completer<void>();
      try {
        await waiter.future.timeout(const Duration(seconds: 4));
      } on TimeoutException {
        // движок не прислал disconnected за таймаут — не блокируем переподключение
      } finally {
        if (identical(_disconnectWaiter, waiter)) _disconnectWaiter = null;
      }
    }
    // даём ядру/туннелю осесть перед повторным connect
    await Future.delayed(const Duration(milliseconds: 350));
  }

  Future<void> toggle() async {
    final status = state.value?.status ?? VpnStatus.disconnected;
    if (status == VpnStatus.connected || status == VpnStatus.connecting) {
      await disconnect();
    } else {
      await connect();
    }
  }
}

/// true пока переподключаемся при смене сервера — чтобы не показывать ложные ошибки
final vpnStateProvider =
    AsyncNotifierProvider<VpnStateNotifier, VpnState>(VpnStateNotifier.new);

/// Замер, начатый сторожем автовыбора.
///
/// Результаты копятся в [results] по мере прихода, [complete] — все ответили
/// или истекли. Отдельный объект, а не голый Future, потому что решать можно
/// и по неполному замеру: соседи отвечают за доли секунды, а мёртвый сервер
/// держит замер до таймаута.
class _AutoSelectMeasure {
  _AutoSelectMeasure(this.serverId);

  /// Сервер, из-за которого замер начат.
  final String serverId;

  final results = <String, ({String id, bool success, int? latencyMs})>{};
  bool complete = false;
  Future<void> done = Future<void>.value();
  var _changed = Completer<void>();

  /// Дождаться следующего результата или конца замера.
  Future<void> get changed => complete ? Future<void>.value() : _changed.future;

  void add(({String id, bool success, int? latencyMs}) result) {
    results[result.id] = result;
    _signal();
  }

  void finish() {
    complete = true;
    _signal();
  }

  void _signal() {
    final fired = _changed;
    _changed = Completer<void>();
    fired.complete();
  }
}
