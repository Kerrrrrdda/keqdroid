import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:keqdroid/l10n/app_localizations.dart';
import 'package:keqdroid/shared/ui/expressive.dart';
import 'package:keqdroid/shared/ui/server_avatar.dart';

import '../../services/exit_ip_service.dart';

/// Чип «Подключено к …» под кнопкой подключения.
///
/// Тональная пилюля вместо обводки: у M3E это штатный вид активного статуса,
/// а тот же secondaryContainer носит активный сервер в списке. Нажатие везёт к
/// его строке в списке — найти её среди полусотни других иначе только
/// свайпами.
///
/// Ведущим элементом — флаг страны выхода, той же формы, что флаги серверов.
/// Он не отдельной ячейкой в полосе показателей: та стоит сеткой 2×2, и пятая
/// ячейка ломала её в 3+2 с дырой. Нажатие на флаг на время подменяет текст
/// чипа адресом, нажатие на адрес его копирует. Сам адрес постоянно не виден:
/// скриншоты главного экрана уходят в чаты и issue.
class ConnectedStatusChip extends StatefulWidget {
  const ConnectedStatusChip({
    super.key,
    required this.label,
    required this.exit,
    required this.onJumpToActive,
    required this.textStyle,
    required this.verticalPadding,
  });

  final String label;

  /// Выход подключения; без флага чип такой же, как был до него.
  final ExitIp? exit;

  final VoidCallback onJumpToActive;
  final TextStyle? textStyle;
  final double verticalPadding;

  /// Сколько адрес держится вместо подписи, если его не трогать.
  static const revealFor = Duration(seconds: 5);

  static const double flagSize = 22;

  @override
  State<ConnectedStatusChip> createState() => _ConnectedStatusChipState();
}

class _ConnectedStatusChipState extends State<ConnectedStatusChip> {
  bool _revealed = false;
  Timer? _hide;

  @override
  void didUpdateWidget(ConnectedStatusChip old) {
    super.didUpdateWidget(old);
    // Сменился выход (другой сервер) — показанный адрес уже неправда.
    if (old.exit?.ip != widget.exit?.ip) _setRevealed(false);
  }

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  void _setRevealed(bool revealed) {
    _hide?.cancel();
    if (revealed) {
      _hide = Timer(ConnectedStatusChip.revealFor, () => _setRevealed(false));
    }
    if (mounted && revealed != _revealed) {
      setState(() => _revealed = revealed);
    }
  }

  void _onChipTap() {
    final exit = widget.exit;
    if (!_revealed || exit == null) {
      widget.onJumpToActive();
      return;
    }
    unawaited(Clipboard.setData(ClipboardData(text: exit.ip)));
    _setRevealed(false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context)!.settingsIpCopied)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final exit = widget.exit;
    final flag = exit?.flag;
    final revealed = _revealed && flag != null;
    final shape = RoundedRectangleBorder(
      borderRadius: ExpressiveShape.radius(ExpressiveShape.full),
    );

    final text = Text(
      revealed ? exit!.ip : widget.label,
      key: ValueKey(revealed),
      textAlign: TextAlign.center,
      textDirection: revealed ? TextDirection.ltr : null,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: widget.textStyle?.copyWith(
        color: scheme.onSecondaryContainer,
        // Цифры адреса одной ширины — строка не дрожит при смене выхода.
        fontFeatures:
            revealed ? const [FontFeature.tabularFigures()] : null,
      ),
    );
    // Сначала гаснет прежний текст, потом появляется новый: два текста на
    // одном месте одновременно читались кашей. Адрес выезжает из-за флага от
    // начала строки (слева направо, в RTL — справа налево); подпись просто
    // проявляется.
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final swapped = AnimatedSwitcher(
      duration: ExpressiveMotion.durationDefault,
      switchInCurve: const Interval(
        0.3,
        1,
        curve: ExpressiveMotion.emphasizedDecelerate,
      ),
      switchOutCurve: const Interval(0.6, 1),
      // Уходящий текст размер не держит: чип подстраивается под новый сразу,
      // одним движением с появлением, а не догоняет его после.
      layoutBuilder: (current, previous) => Stack(
        alignment: AlignmentDirectional.centerStart,
        children: [
          for (final old in previous)
            PositionedDirectional(start: 0, top: 0, bottom: 0, child: old),
          ?current,
        ],
      ),
      transitionBuilder: (child, animation) {
        final faded = FadeTransition(opacity: animation, child: child);
        if (child.key != const ValueKey(true)) return faded;
        // Маска, а не изменение ширины: адрес с первого кадра занимает своё
        // место, и чип сужается под него плавно, а не схлопывается к флагу.
        return ClipRect(
          clipper: _RevealFromStart(animation, rtl: rtl),
          child: faded,
        );
      },
      child: text,
    );

    // Кнопка флага выше строки текста на 8dp — на столько же меньше поле
    // сверху и снизу, и чип с флагом той же высоты, что без него.
    final inset = flag != null ? 4.0 : 0.0;
    return Tooltip(
      message: revealed ? l10n.exitIpLabel : l10n.serversJumpToActive,
      waitDuration: const Duration(milliseconds: 600),
      child: Material(
        color: scheme.secondaryContainer,
        shape: shape,
        child: InkWell(
          onTap: _onChipTap,
          customBorder: shape,
          child: Semantics(
            button: true,
            child: AnimatedSize(
              duration: ExpressiveMotion.durationFast,
              curve: ExpressiveMotion.emphasized,
              child: Padding(
                padding: EdgeInsetsDirectional.fromSTEB(
                  flag != null ? 6 : 16,
                  widget.verticalPadding - inset,
                  16,
                  widget.verticalPadding - inset,
                ),
                child: flag == null
                    ? swapped
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Semantics(
                            button: true,
                            label: l10n.exitIpLabel,
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: () => _setRevealed(!_revealed),
                              child: Padding(
                                padding: const EdgeInsets.all(3),
                                child: ServerAvatar(
                                  flag: flag,
                                  protocol: '',
                                  size: ConnectedStatusChip.flagSize,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Flexible(child: swapped),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Открывает содержимое от начала строки — со стороны флага — по мере
/// [progress].
class _RevealFromStart extends CustomClipper<Rect> {
  _RevealFromStart(this.progress, {required this.rtl})
      : super(reclip: progress);

  final Animation<double> progress;
  final bool rtl;

  @override
  Rect getClip(Size size) {
    final width = size.width * progress.value.clamp(0.0, 1.0);
    return rtl
        ? Rect.fromLTWH(size.width - width, 0, width, size.height)
        : Rect.fromLTWH(0, 0, width, size.height);
  }

  @override
  bool shouldReclip(_RevealFromStart old) =>
      old.progress != progress || old.rtl != rtl;
}
