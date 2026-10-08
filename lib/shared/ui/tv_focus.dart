import 'package:flutter/material.dart';

import 'package:keqdroid/platform/platform_bootstrap.dart';
import 'package:keqdroid/shared/ui/expressive.dart';

/// Фокус пульта на телевизоре — так, как его показывает Material Design для TV
/// (`androidx.tv.material3`, ListItemDefaults): элемент заливается
/// `inverseSurface`, содержимое берёт парный цвет, и сам он подрастает на 5%.
/// Обводки нет: в M3 выделение несёт контейнер, а не рамка вокруг него.
///
/// На телефоне и ПК обёртка ничего не делает — там фокус либо не нужен, либо
/// рисуется слоем состояния, как обычно.
abstract final class TvFocus {
  static bool get enabled => PlatformBootstrap.isTelevision;

  /// Насколько подрастает элемент в фокусе — как у списков Material for TV.
  static const focusedScale = 1.05;

  /// Плавающая кнопка в фокусе. Строится внутри обёртки, потому что берёт
  /// цвета из темы, а в фокусе тема у неё уже инверсная.
  static Widget fab(WidgetBuilder builder) => TvFocusHighlight(
        radius: BorderRadius.circular(ExpressiveShape.largeIncreased),
        child: Builder(builder: builder),
      );

  /// Схема для содержимого выделенного элемента.
  ///
  /// Всё, что внутри берёт цвет из темы (текст, значки, переключатели, свои
  /// контейнеры), само встаёт на инверсную заливку: поверхности становятся
  /// `inverseSurface`, текст — `onInverseSurface`, акцент — `inversePrimary`.
  /// Красить каждую надпись по отдельности не приходится.
  static ColorScheme invert(ColorScheme s) {
    final muted = Color.lerp(s.onInverseSurface, s.inverseSurface, 0.25)!;
    return s.copyWith(
      brightness:
          s.brightness == Brightness.light ? Brightness.dark : Brightness.light,
      surface: s.inverseSurface,
      onSurface: s.onInverseSurface,
      onSurfaceVariant: muted,
      surfaceContainerLowest: s.inverseSurface,
      surfaceContainerLow: s.inverseSurface,
      surfaceContainer: s.inverseSurface,
      surfaceContainerHigh: s.inverseSurface,
      surfaceContainerHighest: s.inverseSurface,
      primary: s.inversePrimary,
      // Залитые элементы (плавающая кнопка, индикатор рейки) встают в тот же
      // вид, что и строки, а не остаются своим цветом поверх инверсной заливки.
      primaryContainer: s.inverseSurface,
      onPrimaryContainer: s.onInverseSurface,
      secondaryContainer: s.inverseSurface,
      onSecondaryContainer: s.onInverseSurface,
      tertiaryContainer: s.inverseSurface,
      onTertiaryContainer: s.onInverseSurface,
      inverseSurface: s.surface,
      onInverseSurface: s.onSurface,
      inversePrimary: s.primary,
      outline: muted,
      outlineVariant: Color.lerp(s.onInverseSurface, s.inverseSurface, 0.6),
    );
  }

  /// Кнопки на телевизоре: в фокусе — та же инверсная заливка, без обводки и
  /// без полупрозрачного слоя поверх. Вне фокуса — цвета [base], то есть всё
  /// как было: обычный merge отдал бы свойство целиком и затёр бы их.
  static ButtonStyle buttonStyle(ColorScheme s, [ButtonStyle? base]) {
    WidgetStateProperty<Color?> layered(
      Color focused,
      WidgetStateProperty<Color?>? under,
    ) =>
        WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.focused)
              ? focused
              : under?.resolve(states),
        );
    return (base ?? const ButtonStyle()).copyWith(
      backgroundColor: layered(s.inverseSurface, base?.backgroundColor),
      foregroundColor: layered(s.onInverseSurface, base?.foregroundColor),
      iconColor: layered(s.onInverseSurface, base?.iconColor),
      overlayColor: layered(Colors.transparent, base?.overlayColor),
    );
  }

  /// Кнопка-значок своего цвета. Цвет задаётся здесь, а не у Icon и не через
  /// IconButton.color: те перебивают фокус, и на телевизоре тёмный значок
  /// терялся на тёмной заливке.
  static ButtonStyle iconButtonStyle(
    BuildContext context, {
    Color? color,
    ButtonStyle? base,
  }) {
    final style = (base ?? const ButtonStyle()).copyWith(
      foregroundColor: color == null ? null : WidgetStatePropertyAll(color),
    );
    return enabled ? buttonStyle(Theme.of(context).colorScheme, style) : style;
  }
}

/// Обёртка элемента, который берёт фокус пульта (сам или кто-то внутри него).
///
/// Сама обёртка фокус не забирает и в обходе не участвует: она только слышит,
/// что фокус у её содержимого. Свою заливку подкладывает снизу — для строк без
/// собственного фона (стандартные переключатели в группе). Элементам со своим
/// контейнером, заданным снаружи цветом, нужно спросить [containerOf].
class TvFocusHighlight extends StatefulWidget {
  const TvFocusHighlight({super.key, required this.child, this.radius});

  final Widget child;

  /// Форма заливки — та же, что у самого элемента.
  final BorderRadiusGeometry? radius;

  /// Цвет заливки, если выше по дереву элемент в фокусе; null — не в фокусе
  /// (или это не телевизор).
  static Color? containerOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_TvFocusScope>()
      ?.container;

  @override
  State<TvFocusHighlight> createState() => _TvFocusHighlightState();
}

class _TvFocusHighlightState extends State<TvFocusHighlight>
    with SingleTickerProviderStateMixin {
  // Только на телевизоре: обёртка стоит в каждой строке групп, и на телефоне
  // контроллер был бы лишним. Не late — ленивое поле создавалось бы в dispose,
  // посреди размонтирования, и падало бы ассертом.
  AnimationController? _lift;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    if (TvFocus.enabled) _lift = AnimationController.unbounded(vsync: this);
  }

  @override
  void dispose() {
    _lift?.dispose();
    super.dispose();
  }

  void _onFocusChange(bool focused) {
    final lift = _lift;
    if (focused == _focused || lift == null) return;
    setState(() => _focused = focused);
    ExpressiveMotion.springTo(
      lift,
      focused ? 1 : 0,
      spring: ExpressiveMotion.spatialFast,
    );
  }

  @override
  Widget build(BuildContext context) {
    final lift = _lift;
    if (lift == null) return widget.child;
    // Сегмент списка обёрнут сам, а группа оборачивает каждую свою строку —
    // вложенная пара подняла бы элемент дважды и залила бы его два раза.
    if (context.findAncestorStateOfType<_TvFocusHighlightState>() != null) {
      return widget.child;
    }
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // Одна и та же структура в обоих состояниях, меняются только значения:
    // перестройка дерева на фокусе пересоздала бы содержимое, и фокус ушёл бы
    // вместе с ним. Полупрозрачный слой фокуса InkWell внутри гасится: заливка
    // уже показывает фокус, второй слой лёг бы пятном поверх неё.
    final content = _TvFocusScope(
      container: _focused ? scheme.inverseSurface : null,
      child: Theme(
        data: theme.copyWith(
          focusColor: Colors.transparent,
          colorScheme: _focused ? TvFocus.invert(scheme) : scheme,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _focused ? scheme.inverseSurface : null,
            borderRadius: widget.radius,
          ),
          child: widget.child,
        ),
      ),
    );

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: _onFocusChange,
      child: AnimatedBuilder(
        animation: lift,
        builder: (context, child) => Transform.scale(
          scale: 1 + (TvFocus.focusedScale - 1) * lift.value,
          child: child,
        ),
        child: content,
      ),
    );
  }
}

class _TvFocusScope extends InheritedWidget {
  const _TvFocusScope({required this.container, required super.child});

  final Color? container;

  @override
  bool updateShouldNotify(_TvFocusScope oldWidget) =>
      container != oldWidget.container;
}
