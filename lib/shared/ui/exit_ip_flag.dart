import 'package:flutter/material.dart';
import 'package:keqdroid/l10n/app_localizations.dart';
import 'package:keqdroid/shared/ui/app_theme.dart';
import 'package:keqdroid/shared/ui/server_avatar.dart';

import '../../models/server_flag.dart';
import '../../services/exit_ip_service.dart';

/// Флаг страны выхода в чипе «Подключено к …». Той же формы, что флаги в
/// списке серверов: это [ServerAvatar], и выбранная форма иконок действует и
/// здесь.
///
/// Сам адрес на главном экране не пишется: скриншоты главного экрана уходят в
/// чаты и issue, и светить там IP незачем. Он — в шторке по нажатию.
class ExitIpFlagButton extends StatelessWidget {
  const ExitIpFlagButton({super.key, required this.exit, required this.flag});

  final ExitIp exit;
  final FlagArt flag;

  static const double size = 22;

  @override
  Widget build(BuildContext context) {
    final label = AppLocalizations.of(context)!.exitIpLabel;
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => showExitIpSheet(context, exit, flag),
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: ServerAvatar(flag: flag, protocol: '', size: size),
          ),
        ),
      ),
    );
  }
}

/// Шторка с одной задачей: флаг, адрес и код страны. Адрес выделяется и
/// копируется как обычный текст — отдельная кнопка для этого лишняя.
Future<void> showExitIpSheet(BuildContext context, ExitIp exit, FlagArt flag) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final textTheme = Theme.of(ctx).textTheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ServerAvatar(flag: flag, protocol: '', size: 40),
                const SizedBox(width: 16),
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectableText(
                        exit.ip,
                        textDirection: TextDirection.ltr,
                        style: textTheme.headlineSmall
                            ?.copyWith(color: AppTheme.text(ctx)),
                      ),
                      Text(
                        exit.countryCode ?? flag.countryCode ?? '',
                        style: textTheme.labelLarge
                            ?.copyWith(color: AppTheme.textLight(ctx)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
