part of 'providers.dart';

final ruleListServiceProvider = Provider<RuleListService>((ref) {
  final storage = ref.read(storageProvider);
  return RuleListService(
    localProxyPort: () => _activeLocalHttpProxyPort(ref, storage),
  );
});

/// Состояние списков по ссылкам из полей маршрутизации, по ссылке.
///
/// Новая ссылка скачивается, как только поле сохранено; дальше списки
/// обновляются раз в сутки — при возвращении в приложение и при каждом
/// подключении, уже через туннель. Скачанное доезжает до ядра на следующем
/// подключении, как и любая другая правка списков.
class RuleListsNotifier extends Notifier<Map<String, RuleListStatus>> {
  final _lastAttempt = <String, DateTime>{};
  Timer? _syncDebounce;
  bool _pruned = false;
  bool _refreshing = false;
  bool _pending = false;
  bool _pendingRetryFailed = false;

  /// Неудачную попытку не повторяем чаще: без связи с хостом списка каждое
  /// возвращение в приложение иначе стоило бы таймаута в фоне.
  static const _retryAfter = Duration(minutes: 10);

  @override
  Map<String, RuleListStatus> build() {
    final lifecycle = AppLifecycleListener(
      onResume: () => unawaited(refreshStale()),
    );
    ref.onDispose(lifecycle.dispose);
    ref.onDispose(() => _syncDebounce?.cancel());

    // Только что поднятый туннель — повод повторить и неудачные: чаще всего
    // список не скачался потому, что его хост закрыт без VPN.
    ref.listen<bool>(
      vpnStateProvider.select((a) => a.value?.status == VpnStatus.connected),
      (previous, connected) {
        if (connected && previous != true) {
          unawaited(refreshStale(retryFailed: true));
        }
      },
    );

    // Поле сохраняется на паузе в наборе, и ссылка, которую ещё печатают,
    // успела бы уйти на скачивание по кусочку. Ждём, пока правка устоится.
    ref.listen<String?>(
      settingsNotifierProvider.select((a) {
        final s = a.value;
        return s == null ? null : _allUrls(s).join('\n');
      }),
      (_, urls) {
        _syncDebounce?.cancel();
        if (urls == null) return;
        // Без ссылок ждать нечего: остаётся только убрать лишнее.
        if (urls.isEmpty) {
          unawaited(_sync());
          return;
        }
        _syncDebounce = Timer(const Duration(milliseconds: 1500), () {
          unawaited(_sync());
        });
      },
      fireImmediately: true,
    );
    return const {};
  }

  static List<String> _allUrls(AppSettings s) => {
        ...ruleListUrls(s.directRules),
        ...ruleListUrls(s.proxyRules),
        ...ruleListUrls(s.blockedRules),
      }.toList();

  Future<void> _sync() async {
    final settings = await ref.read(settingsNotifierProvider.future);
    if (!ref.mounted) return;
    final urls = _allUrls(settings);
    final service = ref.read(ruleListServiceProvider);
    final next = <String, RuleListStatus>{};
    for (final url in urls) {
      next[url] = state[url] ?? await service.status(url);
    }
    if (!ref.mounted) return;
    state = next;
    // Чистим один раз за запуск, а не на каждой правке: вырезанная и тут же
    // вставленная обратно ссылка не должна скачиваться заново.
    if (!_pruned) {
      _pruned = true;
      await service.prune(urls.toSet());
    }
    await refreshStale();
  }

  /// Обновляет списки, которые не обновлялись сутки или не скачивались вовсе.
  ///
  /// Скачивания идут по одному. Вызов посреди прохода не теряется: новая
  /// ссылка или поднявшийся туннель дают ещё один проход следом.
  Future<void> refreshStale({bool retryFailed = false}) async {
    _pendingRetryFailed = _pendingRetryFailed || retryFailed;
    if (_refreshing) {
      _pending = true;
      return;
    }
    _refreshing = true;
    try {
      do {
        _pending = false;
        final retry = _pendingRetryFailed;
        _pendingRetryFailed = false;
        await _refreshPass(retryFailed: retry);
      } while (_pending && ref.mounted);
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _refreshPass({required bool retryFailed}) async {
    for (final url in state.keys.toList()) {
      if (!ref.mounted) return;
      final current = state[url];
      if (current == null) continue;
      final now = DateTime.now();
      final updated = current.updatedAt;
      if (updated != null &&
          now.difference(updated) < RuleListService.staleAfter) {
        continue;
      }
      final last = _lastAttempt[url];
      if (!retryFailed && last != null && now.difference(last) < _retryAfter) {
        continue;
      }
      _lastAttempt[url] = now;
      state = {...state, url: current.copyWith(loading: true)};
      final result = await ref.read(ruleListServiceProvider).refresh(url);
      if (!ref.mounted) return;
      if (state.containsKey(url)) state = {...state, url: result};
    }
  }
}

final ruleListsProvider =
    NotifierProvider<RuleListsNotifier, Map<String, RuleListStatus>>(
  RuleListsNotifier.new,
);
