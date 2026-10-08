part of '../settings_tab.dart';

/// Настройки десктопа: трей и автозапуск, на Windows и Linux.
///
/// Экран с состоянием, потому что автозапуск живёт не только в наших
/// настройках: на Windows обычный — в ключе реестра Run, повышенный — задачей
/// планировщика, на Linux — ярлыком в `~/.config/autostart`. Всё это можно
/// снести мимо приложения, поэтому при открытии экрана переключатели
/// сверяются с системой.
class _DesktopSettingsScreen extends ConsumerStatefulWidget {
  const _DesktopSettingsScreen();

  @override
  ConsumerState<_DesktopSettingsScreen> createState() =>
      _DesktopSettingsScreenState();
}

class _DesktopSettingsScreenState
    extends ConsumerState<_DesktopSettingsScreen> {
  @override
  void initState() {
    super.initState();
    unawaited(_syncWithSystem());
  }

  Future<void> _save(AppSettings next) async {
    await ref.read(settingsNotifierProvider.notifier).save(next);
    await WindowsDesktopService.applySettings(next);
  }

  /// Приводит настройки к тому, что на самом деле сделано в системе.
  ///
  /// Без спроса UAC: экран всего лишь открыли. Если задачу планировщика удалили
  /// руками или папку с приложением перенесли (задача осталась на старом пути),
  /// переключатель честно гаснет, и включить его можно заново.
  Future<void> _syncWithSystem() async {
    if (Platform.isLinux) {
      final enabled = LinuxAutostart.isEnabled();
      final settings = ref.read(settingsNotifierProvider).value;
      if (!mounted || settings == null) return;
      if (settings.launchAtStartup == enabled) return;
      await ref
          .read(settingsNotifierProvider.notifier)
          .save(settings.copyWith(launchAtStartup: enabled));
      return;
    }
    if (!Platform.isWindows) return;
    final elevated = await WindowsDesktopService.isLaunchAtStartupElevated();
    final run = await WindowsDesktopService.isLaunchAtStartupEnabled();
    if (!mounted) return;
    final settings = ref.read(settingsNotifierProvider).value;
    if (settings == null) return;
    final actual = settings.copyWith(
      launchAtStartup: elevated || run,
      launchAtStartupElevated: elevated,
    );
    if (actual == settings) return;
    await ref.read(settingsNotifierProvider.notifier).save(actual);
  }

  /// Меняет автозапуск и сохраняет то, что из этого вышло.
  ///
  /// Задачу планировщика заводит и сносит только администратор, поэтому здесь
  /// может всплыть UAC — один раз, в момент переключения. Отказались — сохраним
  /// не намерение, а факт: оба переключателя обязаны показывать то, что система
  /// действительно делает на входе в систему.
  Future<void> _applyAutostart(AppSettings next) async {
    if (Platform.isLinux) {
      await LinuxAutostart.setEnabled(next.launchAtStartup);
      if (!mounted) return;
      await ref.read(settingsNotifierProvider.notifier).save(
            next.copyWith(launchAtStartup: LinuxAutostart.isEnabled()),
          );
      return;
    }
    final ok = await WindowsDesktopService.applyLaunchAtStartup(
      enabled: next.launchAtStartup,
      elevated: next.launchAtStartupElevated,
      allowElevation: true,
    );
    final elevated = await WindowsDesktopService.isLaunchAtStartupElevated();
    final run = await WindowsDesktopService.isLaunchAtStartupEnabled();
    if (!mounted) return;
    await ref.read(settingsNotifierProvider.notifier).save(
          next.copyWith(
            launchAtStartup: elevated || run,
            launchAtStartupElevated: elevated,
          ),
        );
    if (ok || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context)!.settingsAutostartAdminFailed),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settings =
        ref.watch(settingsNotifierProvider).value ?? const AppSettings();

    // Строки — те же переключатели, что во «Внешнем виде»: кружок с иконкой,
    // нажатие по всей строке, сегменты одной группы. Своя плоская карточка без
    // иконки была здесь единственной такой на все настройки.
    //
    // Подписи под названиями здесь были пересказом самих названий, поэтому их
    // нет вовсе. Остался только абзац под группой — он отвечает на вопрос
    // «почему серое», из названия этого не узнать.
    Widget note(String text) => Padding(
          padding: const EdgeInsets.only(top: 6, left: 4, right: 4),
          child: Text(
            text,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: AppTheme.textLight(context)),
          ),
        );

    final linux = Platform.isLinux;
    return ExpressivePage(
      title: linux ? l10n.settingsDesktopTitleLinux : l10n.settingsDesktopTitle,
      physics: const ClampingScrollPhysics(),
      children: [
        ExpressiveGroup(
          children: [
            _AppearanceSwitchTile(
              icon: Icons.close_fullscreen_rounded,
              title: l10n.settingsMinimizeToTray,
              value: settings.minimizeToTray,
              onChanged: (v) => _save(settings.copyWith(minimizeToTray: v)),
            ),
            _AppearanceSwitchTile(
              icon: Icons.power_settings_new_rounded,
              title: linux
                  ? l10n.settingsLaunchAtLogin
                  : l10n.settingsLaunchAtStartup,
              value: settings.launchAtStartup,
              onChanged: (v) => unawaited(
                _applyAutostart(settings.copyWith(launchAtStartup: v)),
              ),
            ),
            // Повышенного автозапуска на Linux нет: root для TUN даёт polkit
            // при подключении.
            if (!linux)
              _AppearanceSwitchTile(
                icon: Icons.admin_panel_settings_rounded,
                title: l10n.settingsLaunchAtStartupAdmin,
                value: settings.launchAtStartupElevated,
                onChanged: settings.launchAtStartup
                    ? (v) => unawaited(
                          _applyAutostart(
                            settings.copyWith(launchAtStartupElevated: v),
                          ),
                        )
                    : null,
              ),
            _AppearanceSwitchTile(
              icon: Icons.vpn_lock_rounded,
              title: l10n.settingsAutoConnectOnAutostart,
              value: settings.autoConnectLastServer,
              onChanged: settings.launchAtStartup
                  ? (v) => _save(settings.copyWith(autoConnectLastServer: v))
                  : null,
            ),
          ],
        ),
        if (!settings.launchAtStartup)
          note(linux
              ? l10n.settingsAutoConnectRequiresLogin
              : l10n.settingsAutoConnectRequiresAutostart),
      ],
    );
  }
}
