part of '../settings_tab.dart';

// Подписи и цвета структурированных правил нужны и списку на экране, и диалогу
// редактирования. Держим их здесь, а не в каждом State по копии.

String _ruleTypeLabel(AppLocalizations l10n, RuleType t) => switch (t) {
      RuleType.domain => l10n.settingsRoutingRuleTypeDomain,
      RuleType.ipCidr => l10n.settingsRoutingRuleTypeIp,
      RuleType.geoip => l10n.settingsRoutingRuleTypeGeoip,
      RuleType.geosite => l10n.settingsRoutingRuleTypeGeosite,
      RuleType.processName => l10n.settingsRoutingRuleTypeDomain,
    };

// Те же слова, что у строк списков и у «Всё остальное»: одно действие на
// экране называется одинаково, где бы его ни выбирали.
String _ruleActionLabel(AppLocalizations l10n, RuleAction a) => switch (a) {
      RuleAction.direct => l10n.settingsRoutingDirectTitle,
      RuleAction.proxy => l10n.settingsRoutingProxyTitle,
      RuleAction.block => l10n.settingsRoutingBlockTitle,
    };

Color _ruleActionColor(BuildContext context, RuleAction a) => switch (a) {
      RuleAction.direct => AppTheme.green(context),
      RuleAction.proxy => AppTheme.accent(context),
      RuleAction.block => AppTheme.red(context),
    };

IconData _ruleActionIcon(RuleAction a) => switch (a) {
      RuleAction.direct => Icons.call_made_rounded,
      RuleAction.proxy => Icons.vpn_lock_rounded,
      RuleAction.block => Icons.block_rounded,
    };

/// Вход в экран для виджет-теста: сам экран приватный, а путь к нему через
/// «Дополнительно» тесту не нужен.
@visibleForTesting
Widget routingScreenForTest() => const _RoutingScreen();

class _RoutingScreen extends ConsumerStatefulWidget {
  const _RoutingScreen();

  @override
  ConsumerState<_RoutingScreen> createState() => _RoutingScreenState();
}

class _RoutingScreenState extends ConsumerState<_RoutingScreen> {
  late final TextEditingController _directRules;
  late final TextEditingController _proxyRules;
  late final TextEditingController _blockedRules;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    final s = ref.read(settingsNotifierProvider).value;
    _directRules = TextEditingController(
      text: s?.directRules ?? RoutingPresets.defaultDirectRules,
    );
    _proxyRules = TextEditingController(
      text: s?.proxyRules ?? RoutingPresets.defaultProxyRules,
    );
    _blockedRules = TextEditingController(
      text: s?.blockedRules ?? RoutingPresets.defaultBlockedRules,
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _directRules.dispose();
    _proxyRules.dispose();
    _blockedRules.dispose();
    super.dispose();
  }

  void _scheduleSave() {
    setState(() {}); // keep entry counts in sync while typing
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _persist);
  }

  Future<void> _persist() async {
    final current = ref.read(settingsNotifierProvider).value;
    if (current == null) return;
    await ref.read(settingsNotifierProvider.notifier).save(
          current.copyWith(
            directRules: _directRules.text,
            proxyRules: _proxyRules.text,
            blockedRules: _blockedRules.text,
          ),
        );
  }

  /// Сохраняет финальное действие вместе с текущим текстом полей (сбрасывая
  /// debounce), чтобы незакоммиченные правки списков не потерялись.
  Future<void> _saveFinalOutbound(String value) async {
    _debounce?.cancel();
    final current = ref.read(settingsNotifierProvider).value;
    if (current == null) return;
    await ref.read(settingsNotifierProvider.notifier).save(
          current.copyWith(
            directRules: _directRules.text,
            proxyRules: _proxyRules.text,
            blockedRules: _blockedRules.text,
            finalOutbound: value,
          ),
        );
  }

  /// Сперва дописывает несохранённый ввод: нажатие сразу после правки иначе
  /// переподключило бы со старыми списками — сохранение ждёт паузы в наборе.
  Future<void> _reconnect() async {
    _debounce?.cancel();
    await _persist();
    try {
      await ref.read(vpnStateProvider.notifier).reconnectToActiveServer();
    } catch (_) {
      // Исход подключения показывает сам экран VPN, здесь его не дублируем.
    }
  }

  TextEditingController _controllerFor(RoutingField f) => switch (f) {
        RoutingField.direct => _directRules,
        RoutingField.proxy => _proxyRules,
        RoutingField.blocked => _blockedRules,
      };

  Future<void> _applyPreset(RoutingPreset preset, String label) async {
    final ctrl = _controllerFor(preset.field);
    ctrl.text = RoutingPresets.mergeValues(ctrl.text, preset.values);
    await _persist();
    if (!mounted) return;
    setState(() {});
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.settingsRoutingPresetApplied(label))),
    );
  }

  Future<void> _resetToDefaults() async {
    // Единственная кнопка сброса правил (из «Дополнительно» карточка убрана),
    // и она стирает все три списка — спрашиваем подтверждение.
    if (!await _confirmReset(
      context,
      message: AppLocalizations.of(context)!.settingsResetRoutingConfirm,
    )) {
      return;
    }
    if (!mounted) return;
    _directRules.text = RoutingPresets.defaultDirectRules;
    _proxyRules.text = RoutingPresets.defaultProxyRules;
    _blockedRules.text = RoutingPresets.defaultBlockedRules;
    await _persist();
    if (!mounted) return;
    setState(() {});
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.settingsRoutingResetDone)),
    );
  }

  String _presetTitle(AppLocalizations l10n, String id) => switch (id) {
        'ru' => l10n.settingsRoutingPresetRuTitle,
        'ru_geoip' => l10n.settingsRoutingPresetRuGeoipTitle,
        'ru_geosite' => l10n.settingsRoutingPresetRuGeositeTitle,
        'banks' => l10n.settingsRoutingPresetBanksTitle,
        'lan_ips' => l10n.settingsRoutingPresetLanIpsTitle,
        'ads' => l10n.settingsRoutingPresetAdsTitle,
        'ads_geosite' => l10n.settingsRoutingPresetAdsGeositeTitle,
        'streaming' => l10n.settingsRoutingPresetStreamingTitle,
        'messengers' => l10n.settingsRoutingPresetMessengersTitle,
        'telegram_geo' => l10n.settingsRoutingPresetTelegramGeoTitle,
        'refilter' => l10n.settingsRoutingPresetRefilterTitle,
        _ => id,
      };

  String _presetDesc(AppLocalizations l10n, String id) => switch (id) {
        'ru' => l10n.settingsRoutingPresetRuDesc,
        'ru_geoip' => l10n.settingsRoutingPresetRuGeoipDesc,
        'ru_geosite' => l10n.settingsRoutingPresetRuGeositeDesc,
        'banks' => l10n.settingsRoutingPresetBanksDesc,
        'lan_ips' => l10n.settingsRoutingPresetLanIpsDesc,
        'ads' => l10n.settingsRoutingPresetAdsDesc,
        'ads_geosite' => l10n.settingsRoutingPresetAdsGeositeDesc,
        'streaming' => l10n.settingsRoutingPresetStreamingDesc,
        'messengers' => l10n.settingsRoutingPresetMessengersDesc,
        'telegram_geo' => l10n.settingsRoutingPresetTelegramGeoDesc,
        'refilter' => l10n.settingsRoutingPresetRefilterDesc,
        _ => '',
      };

  IconData _presetIcon(String id) => switch (id) {
        'ru' => Icons.flag_rounded,
        'ru_geoip' => Icons.public_rounded,
        'ru_geosite' => Icons.travel_explore_rounded,
        'banks' => Icons.account_balance_rounded,
        'lan_ips' => Icons.lan_rounded,
        'ads' => Icons.block_rounded,
        'ads_geosite' => Icons.block_rounded,
        'streaming' => Icons.play_circle_outline_rounded,
        'messengers' => Icons.chat_bubble_outline_rounded,
        'telegram_geo' => Icons.send_rounded,
        'refilter' => Icons.shield_rounded,
        _ => Icons.tune_rounded,
      };


  /// Подпись строки: записи поля, а со скачанными списками ещё и их домены.
  /// Пока ни один список не скачан, ссылка считается обычной записью, иначе
  /// поле с одной ссылкой называлось бы пустым.
  String _listSubtitle(
    AppLocalizations l10n,
    List<String> entries,
    int linkedDomains,
  ) {
    if (linkedDomains == 0) return l10n.settingsRoutingItemCount(entries.length);
    final plain = entries.where((e) => !isRuleListUrl(e)).length;
    final links = l10n.settingsRoutingLinkDomains(
      linkedDomains,
      _groupedCount(linkedDomains),
    );
    if (plain == 0) return links;
    return l10n.settingsRoutingCountWithLinks(
      l10n.settingsRoutingItemCount(plain),
      links,
    );
  }

  /// Тысячи разделены по-местному, но цифры латинские и в фарси: остальные
  /// числа в приложении печатает код, и персидские стояли бы одни на экране.
  String _groupedCount(int n) {
    final lang = Localizations.localeOf(context).languageCode;
    return NumberFormat.decimalPattern(lang == 'fa' ? 'en' : lang).format(n);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Правила читаются только в момент connect() — при активном туннеле
    // изменения вступят в силу после переподключения.
    final vpnStatus = ref.watch(
      vpnStateProvider.select((a) => a.value?.status),
    );
    final tunnelActive = vpnStatus == VpnStatus.connected ||
        vpnStatus == VpnStatus.connecting;
    final finalOutbound = ref.watch(
      settingsNotifierProvider.select(
        (a) => a.value?.finalOutbound ?? AppSettings.finalOutboundProxy,
      ),
    );
    // Коды из поставляемых geo-баз: по ним подсвечиваем несуществующие токены
    // (ядро на таком коде роняет весь конфиг, поэтому они выкидываются перед
    // подключением) и наполняем пикер кодов.
    final geoIndex =
        ref.watch(geoAssetIndexProvider).value ?? GeoAssetIndex.empty;
    return ExpressivePage(
      title: l10n.settingsRoutingTitle,
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        ExpressiveSpacing.large,
        ExpressiveSpacing.none,
        ExpressiveSpacing.large,
        ExpressiveSpacing.extraLargeIncreased,
      ),
      actions: [
        IconButton(
          tooltip: l10n.routingCheatSheetTitle,
          icon: const Icon(Icons.help_outline_rounded),
          onPressed: () => _showCheatSheet(context, l10n),
        ),
        IconButton(
          tooltip: l10n.settingsResetRoutingTitle,
          icon: const Icon(Icons.restore_rounded),
          onPressed: _resetToDefaults,
        ),
      ],
      children: [
        if (tunnelActive)
          ExpressiveNotice(
            color: AppTheme.orange(context),
            icon: Icons.info_outline_rounded,
            text: l10n.splitTunnelingReconnectHint,
            action: TextButton(
              // Пока туннель поднимается, второе нажатие ничего бы не дало:
              // переподключение само дождётся текущего.
              onPressed: vpnStatus == VpnStatus.connected ? _reconnect : null,
              child: Text(l10n.settingsRoutingReconnect),
            ),
          ),
        ExpressiveSectionHeader(
          l10n.settingsRoutingListsTitle,
          trailing: TextButton.icon(
            onPressed: () => unawaited(_showPresetSheet(context, l10n)),
            icon: const Icon(Icons.playlist_add_rounded),
            label: Text(l10n.settingsRoutingPresetsTitle),
          ),
        ),
        // Три списка и «всё остальное» — одна группа: вместе они и есть ответ
        // на вопрос «куда пойдёт сайт», а «всё остальное» решает судьбу того,
        // что не попало ни в один список выше.
        ExpressiveGroup(
          children: [
            _listRow(
              color: AppTheme.green(context),
              icon: Icons.call_made_rounded,
              title: l10n.settingsRoutingDirectTitle,
              controller: _directRules,
              hint: 'ru, vk.com, .example.com, 10.0.0.0/8',
              l10n: l10n,
              field: RoutingField.direct,
              geoIndex: geoIndex,
            ),
            _listRow(
              color: AppTheme.accent(context),
              icon: Icons.vpn_lock_rounded,
              title: l10n.settingsRoutingProxyTitle,
              controller: _proxyRules,
              hint: 'youtube.com, discord.com, 1.1.1.1',
              l10n: l10n,
              field: RoutingField.proxy,
              geoIndex: geoIndex,
            ),
            _listRow(
              color: AppTheme.red(context),
              icon: Icons.block_rounded,
              title: l10n.settingsRoutingBlockTitle,
              controller: _blockedRules,
              hint: 'doubleclick.net, 0.0.0.0/8',
              l10n: l10n,
              field: RoutingField.blocked,
              geoIndex: geoIndex,
            ),
            _finalRow(l10n, finalOutbound),
          ],
        ),
        ExpressiveSectionHeader(l10n.settingsRoutingAdvancedTitle),
        _advancedRulesCard(context, l10n),
      ],
    );
  }

  // ── Строки группы «Куда идут сайты» ────────────────────────────────────────

  /// На строке меньше этой ширины подпись встаёт над полем: рядом полю
  /// осталось бы меньше половины телефона, и список читался бы по слову.
  static const double _sideBySideWidth = 560;

  /// Колонка подписи: вмещает самое длинное название строки с иконкой.
  static const double _labelWidth = 188;

  Widget _row({
    required Widget label,
    required Widget body,
    bool centerLabel = false,
  }) {
    return ExpressiveGroupTile(
      padding: const EdgeInsets.all(ExpressiveSpacing.medium),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < _sideBySideWidth) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                label,
                const SizedBox(height: ExpressiveSpacing.medium),
                body,
              ],
            );
          }
          return Row(
            crossAxisAlignment: centerLabel
                ? CrossAxisAlignment.center
                : CrossAxisAlignment.start,
            children: [
              SizedBox(width: _labelWidth, child: label),
              const SizedBox(width: ExpressiveSpacing.medium),
              Expanded(child: body),
            ],
          );
        },
      ),
    );
  }

  Widget _rowLabel({
    required IconData icon,
    required Color background,
    required Color foreground,
    required String title,
    required String subtitle,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      children: [
        ExpressiveIconBadge(
          icon: icon,
          background: background,
          foreground: foreground,
        ),
        const SizedBox(width: ExpressiveSpacing.medium),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: theme.textTheme
                    .emphasized(theme.textTheme.titleMedium)
                    ?.copyWith(color: scheme.onSurface),
              ),
              Text(
                subtitle,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _finalRow(AppLocalizations l10n, String current) {
    final scheme = Theme.of(context).colorScheme;
    return _row(
      centerLabel: true,
      label: _rowLabel(
        icon: Icons.alt_route_rounded,
        background: scheme.surfaceContainerHighest,
        foreground: scheme.onSurfaceVariant,
        title: l10n.settingsRoutingFinalTitle,
        subtitle: l10n.settingsRoutingFinalSubtitle,
      ),
      // Варианты в том же порядке и с теми же словами, что строки над ними:
      // «всё остальное» отправляется туда же, куда один из трёх списков.
      body: ExpressiveConnectedButtons<String>(
        segments: [
          ExpressiveSegment(
            value: AppSettings.finalOutboundDirect,
            label: l10n.settingsRoutingDirectTitle,
            icon: Icons.call_made_rounded,
            iconColor: AppTheme.green(context),
          ),
          ExpressiveSegment(
            value: AppSettings.finalOutboundProxy,
            label: l10n.settingsRoutingProxyTitle,
            icon: Icons.vpn_lock_rounded,
            iconColor: AppTheme.accent(context),
          ),
          ExpressiveSegment(
            value: AppSettings.finalOutboundBlock,
            label: l10n.settingsRoutingBlockTitle,
            icon: Icons.block_rounded,
            iconColor: AppTheme.red(context),
          ),
        ],
        selected: current,
        onChanged: _saveFinalOutbound,
      ),
    );
  }


  // ── Структурированные правила (RoutingRule) ────────────────────────────────

  Widget _advancedRulesCard(BuildContext context, AppLocalizations l10n) {
    final rulesAsync = ref.watch(routingRulesProvider);
    // processName-правила не поддержаны в этом редакторе (пер-аппный роутинг —
    // отдельный экран split tunneling); прячем их, чтобы не путать.
    final rules = (rulesAsync.value ?? const <RoutingRule>[])
        .where((r) => r.type != RuleType.processName)
        .toList();
    // Заголовок секции стоит над карточкой, поэтому внутри остаются только
    // сами правила и строка «что это + добавить». Пустого состояния отдельной
    // строкой нет: пояснение рядом с кнопкой и так говорит, что здесь будет.
    return ExpressiveCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final rule in rules) _ruleTile(context, l10n, rule),
          LayoutBuilder(
            builder: (context, constraints) {
              final hint = Text(
                l10n.settingsRoutingAdvancedHint,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              );
              final add = FilledButton.tonalIcon(
                onPressed: () => _openRuleEditor(l10n, null),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: Text(l10n.settingsRoutingAdvancedAdd),
              );
              // На телефоне рядом с кнопкой пояснению осталась бы треть
              // ширины, и оно рассыпалось бы на четыре строки.
              if (constraints.maxWidth < _sideBySideWidth) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    hint,
                    const SizedBox(height: ExpressiveSpacing.medium),
                    add,
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: hint),
                  const SizedBox(width: ExpressiveSpacing.medium),
                  add,
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _ruleTile(
      BuildContext context, AppLocalizations l10n, RoutingRule rule) {
    final color = _ruleActionColor(context, rule.action);
    final valuesPreview = rule.values.join(', ');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
      // Та же подложка, что у полей списков выше: правило — тоже содержимое,
      // а рамка вокруг каждого делала бы из карточки стопку коробок.
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        borderRadius: ExpressiveShape.radius(ExpressiveShape.large),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        rule.name.trim().isEmpty
                            ? valuesPreview
                            : rule.name.trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              color: rule.enabled
                                  ? AppTheme.text(context)
                                  : AppTheme.textLight(context),
                            ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    _pill(_ruleTypeLabel(l10n, rule.type),
                        AppTheme.textLight(context)),
                    const SizedBox(width: 4),
                    _pill(_ruleActionLabel(l10n, rule.action), color),
                  ],
                ),
                if (rule.name.trim().isNotEmpty && valuesPreview.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    valuesPreview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: AppTheme.textLight(context)),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: l10n.settingsRoutingRuleEditTitle,
            icon: Icon(Icons.edit_rounded,
                size: 18, color: AppTheme.textLight(context)),
            onPressed: () => _openRuleEditor(l10n, rule),
          ),
          Switch(
            value: rule.enabled,
            activeThumbColor: color,
            activeTrackColor: color.withValues(alpha: 0.32),
            onChanged: (_) =>
                ref.read(routingRulesProvider.notifier).toggle(rule.id),
          ),
        ],
      ),
    );
  }

  Widget _pill(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(ExpressiveShape.small),
        ),
        child: Text(
          text,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
        ),
      );

  // Использует context/mounted самого State (не переданный параметр), чтобы
  // проверки mounted были «связаны» с BuildContext после await (линтер).
  Future<void> _openRuleEditor(
      AppLocalizations l10n, RoutingRule? existing) async {
    final result = await showDialog<_RuleEditorResult>(
      context: context,
      builder: (_) => _RuleEditorDialog(existing: existing),
    );
    if (result == null || !mounted) return;
    final notifier = ref.read(routingRulesProvider.notifier);
    switch (result) {
      case _RuleSave(:final rule):
        if (existing == null) {
          await notifier.add(rule);
        } else {
          await notifier.updateRule(rule);
        }
      case _RuleDelete():
        if (existing == null) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            content: Text(l10n.settingsRoutingRuleDeleteConfirm),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(l10n.subscriptionsCancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(l10n.subscriptionsDelete),
              ),
            ],
          ),
        );
        if (ok == true) await notifier.remove(existing.id);
    }
  }

  // ── Шпаргалка «как писать правила» ─────────────────────────────────────────

  void _showCheatSheet(BuildContext context, AppLocalizations l10n) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.routingCheatSheetTitle,
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(color: AppTheme.text(context)),
              ),
              const SizedBox(height: 10),
              ..._cheatLines(context, l10n.routingCheatSheetBody),
            ],
          ),
        ),
      ),
    );
  }

  /// Разбивает текст шпаргалки на строки; строки с префиксом `## ` рисуются как
  /// заголовки секций (акцентом), остальные — обычным текстом. Так один
  /// локализованный текст остаётся живой заметкой, а не стеной.
  List<Widget> _cheatLines(BuildContext context, String body) {
    final out = <Widget>[];
    for (final raw in body.split('\n')) {
      final isHeader = raw.startsWith('## ');
      if (raw.trim().isEmpty) {
        out.add(const SizedBox(height: 10));
        continue;
      }
      out.add(Padding(
        padding: EdgeInsets.only(top: isHeader ? 8 : 1, bottom: isHeader ? 4 : 1),
        child: Text(
          isHeader ? raw.substring(3) : raw,
          style: isHeader
              ? Theme.of(context)
                  .textTheme
                  .emphasized(Theme.of(context).textTheme.labelLarge)
                  ?.copyWith(
                    letterSpacing: 0.3,
                    color: AppTheme.accent(context),
                  )
              : Theme.of(context).textTheme.bodyMedium?.copyWith(
                    height: 1.45,
                    color: AppTheme.text(context),
                  ),
        ),
      ));
    }
    return out;
  }

  // Шпаргалки по синтаксису внизу экрана больше нет: она слово в слово
  // повторяла первые строки шторки «Как писать правила», которая открывается
  // кнопкой в шапке — та же справка, только полная. Подсказка формата осталась
  // там, где её читают: `hintText` каждого поля показывает готовый пример.

  /// «Готовые списки»: выбранный сразу дописывается в свой список.
  ///
  /// Раньше выбор и добавление были двумя шагами — пункт в карточке и кнопка
  /// «Добавить» рядом. Шторку открывают ровно затем, чтобы добавить, а
  /// описание пресета, по которому решают, есть в самой шторке.
  Future<void> _showPresetSheet(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    final theme = Theme.of(context);
    final chosen = await showModalBottomSheet<RoutingPreset>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.8,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                  child: Text(
                    l10n.settingsRoutingPresetsTitle,
                    style: theme.textTheme
                        .emphasized(theme.textTheme.titleMedium)
                        ?.copyWith(color: AppTheme.text(context)),
                  ),
                ),
                ExpressiveGroup(
                  children: [
                    for (final preset in RoutingPresets.all)
                      ExpressiveActionTile(
                        icon: _presetIcon(preset.id),
                        title: _presetTitle(l10n, preset.id),
                        subtitle: _presetDesc(l10n, preset.id),
                        onTap: () => Navigator.pop(ctx, preset),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    await _applyPreset(chosen, _presetTitle(l10n, chosen.id));
  }

  Widget _listRow({
    required Color color,
    required IconData icon,
    required String title,
    required TextEditingController controller,
    required String hint,
    required AppLocalizations l10n,
    required RoutingField field,
    required GeoAssetIndex geoIndex,
  }) {
    final unknown = unknownGeoTokens(controller.text, geoIndex);
    final entries = routingEntries(controller.text);
    // Статус есть только у сохранённых ссылок: недопечатанная ещё не ушла в
    // настройки, и строки под ней пока нет.
    final statuses = ref.watch(ruleListsProvider);
    final lists = [
      for (final url in ruleListUrls(controller.text)) ?statuses[url],
    ];
    final linkedDomains = lists.fold(0, (sum, s) => sum + s.domains);
    return _row(
      label: _rowLabel(
        icon: icon,
        background: color.withValues(alpha: 0.16),
        foreground: color,
        title: title,
        subtitle: _listSubtitle(l10n, entries, linkedDomains),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _listField(
            controller: controller,
            hint: hint,
            l10n: l10n,
            field: field,
            geoIndex: geoIndex,
          ),
          if (lists.isNotEmpty) ...[
            const SizedBox(height: ExpressiveSpacing.small),
            for (final status in lists) _ruleListLine(l10n, status),
          ],
          if (Platform.isAndroid &&
              linkedDomains > ruleListPhoneDomainBudget &&
              ref.watch(activeVpnBackendProvider) == VpnBackend.xray) ...[
            const SizedBox(height: ExpressiveSpacing.small),
            ExpressiveNotice(
              color: AppTheme.orange(context),
              icon: Icons.memory_rounded,
              text: l10n.ruleListMemoryWarning(
                _groupedCount(ruleListPhoneDomainBudget),
              ),
            ),
          ],
          if (unknown.isNotEmpty) ...[
            const SizedBox(height: ExpressiveSpacing.small),
            _unknownGeoWarning(context, l10n, unknown),
          ],
        ],
      ),
    );
  }

  /// Одна строка под полем на каждую ссылку: сколько в списке доменов и когда
  /// он обновился, либо почему не скачался. Скачанное раньше при неудаче
  /// остаётся в силе, поэтому такая строка не красная, а предупреждающая.
  Widget _ruleListLine(AppLocalizations l10n, RuleListStatus s) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final parsedHost = Uri.tryParse(s.url)?.host ?? '';
    final host = ltrIsolate(parsedHost.isEmpty ? s.url : parsedHost);
    String domains() =>
        l10n.ruleListDomainCount(s.domains, _groupedCount(s.domains));
    String when() => timeAgo(l10n, s.updatedAt!);
    final (IconData icon, Color color, String text) = switch (s) {
      _ when s.loading || (!s.loaded && s.failure == null) => (
          Icons.cloud_sync_outlined,
          scheme.onSurfaceVariant,
          l10n.ruleListLoading(host),
        ),
      _ when s.loaded && s.failure == null => (
          Icons.cloud_done_outlined,
          scheme.onSurfaceVariant,
          l10n.ruleListLoaded(host, domains(), when()),
        ),
      _ when s.loaded => (
          Icons.cloud_off_outlined,
          AppTheme.orange(context),
          l10n.ruleListLoadedStale(host, domains(), when()),
        ),
      _ => (
          Icons.error_outline_rounded,
          scheme.error,
          switch (s.failure) {
            RuleListFailure.insecure => l10n.ruleListFailedInsecure(host),
            RuleListFailure.http =>
              l10n.ruleListFailedHttp(host, s.httpStatus ?? 0),
            RuleListFailure.tooLarge => l10n.ruleListFailedTooLarge(host),
            RuleListFailure.empty => l10n.ruleListFailedEmpty(host),
            RuleListFailure.network || null =>
              l10n.ruleListFailedNetwork(host),
          },
        ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: ExpressiveSpacing.small),
          Expanded(
            child: Text(
              text,
              // Оранжевый текст на светлой теме не проходит по контрасту, его
              // несёт иконка; красный проходит и остаётся у ошибки целиком.
              style: theme.textTheme.bodySmall?.copyWith(
                color: color == scheme.error ? color : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Поле списка — залитое, на уровень ниже строки, а не с рамкой, как поля
  /// по теме. Здесь оно и есть содержимое строки: рамка в каждой из трёх строк
  /// дробила бы группу на коробки, а тёмная подложка читается как «сам список».
  /// Рамка остаётся только в фокусе — боковым зрением видно, где сейчас ввод.
  Widget _listField({
    required TextEditingController controller,
    required String hint,
    required AppLocalizations l10n,
    required RoutingField field,
    required GeoAssetIndex geoIndex,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final radius = ExpressiveShape.radius(ExpressiveShape.large);
    final withPicker = !geoIndex.isEmpty;
    return Stack(
      children: [
        TextField(
          controller: controller,
          textDirection: technicalInputDirection,
          minLines: 2,
          maxLines: 8,
          style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurface),
          decoration: InputDecoration(
            hintText: hint,
            filled: true,
            fillColor: scheme.surfaceContainerLowest,
            border: OutlineInputBorder(
              borderRadius: radius,
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: radius,
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: radius,
              borderSide: BorderSide(color: scheme.primary, width: 2),
            ),
            // Справа место под кнопку кодов, чтобы текст под неё не заезжал.
            contentPadding: EdgeInsetsDirectional.fromSTEB(
              16,
              14,
              withPicker ? 48 : 16,
              14,
            ),
          ),
          onChanged: (_) => _scheduleSave(),
        ),
        if (withPicker)
          PositionedDirectional(
            top: 4,
            end: 4,
            child: IconButton(
              tooltip: l10n.settingsRoutingGeoPickerTooltip,
              icon: const Icon(Icons.travel_explore_rounded, size: 20),
              color: scheme.onSurfaceVariant,
              onPressed: () => _showGeoCodePicker(field, geoIndex),
            ),
          ),
      ],
    );
  }

  /// Токены, которых нет в поставляемых базах. Ядро на неизвестном geo-коде не
  /// игнорирует правило, а падает на разборе всего конфига, поэтому такие записи
  /// выкидываются перед подключением — раньше молча, из-за чего «geoip:telegram»
  /// выглядел рабочим и вопрос «почему ТГ не учитывается» был без ответа.
  Widget _unknownGeoWarning(
    BuildContext context,
    AppLocalizations l10n,
    List<String> tokens,
  ) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppTheme.orange(context).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(ExpressiveShape.medium),
        border: Border.all(
          color: AppTheme.orange(context).withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  size: 16, color: AppTheme.orange(context)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.settingsRoutingGeoUnknownTitle,
                  style: Theme.of(context)
                      .textTheme
                      .emphasized(Theme.of(context).textTheme.labelMedium)
                      ?.copyWith(color: AppTheme.orange(context)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            tokens.join(', '),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: AppTheme.text(context),
                ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.settingsRoutingGeoUnknownHint,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  height: 1.35,
                  color: AppTheme.textLight(context),
                ),
          ),
        ],
      ),
    );
  }

  /// Пикер кодов из реальных баз: 1500+ geosite и 260+ geoip кодов руками не
  /// вспомнишь, а опечатка молча ломает правило.
  Future<void> _showGeoCodePicker(
    RoutingField field,
    GeoAssetIndex index,
  ) async {
    final token = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _GeoCodePickerSheet(index: index),
    );
    if (token == null || token.isEmpty) return;
    final ctrl = _controllerFor(field);
    ctrl.text = RoutingPresets.mergeValues(ctrl.text, [token]);
    await _persist();
    if (!mounted) return;
    setState(() {});
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.settingsRoutingPresetApplied(token))),
    );
  }
}
