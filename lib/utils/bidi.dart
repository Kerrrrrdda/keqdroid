/// Изоляция латинских «технических» значений внутри RTL-интерфейса.
///
/// В персидской локали абзац идёт справа налево, и строка вроде
/// `621.8 / ∞ GiB` или `266 ms` разваливается: цифры и латиница — сильные
/// LTR-символы, а пробелы, слэш и `∞` между ними нейтральные, поэтому
/// двунаправленный алгоритм расставляет куски по направлению абзаца и на
/// экране получается `GiB ∞ / 621.8` и `ms 266`.
///
/// Изолят (U+2066 … U+2069) объявляет кусок отдельным LTR-островом: внутри он
/// читается слева направо, а снаружи не влияет на порядок соседей. Именно
/// изолят, а не устаревшая пара LRE/PDF — та ещё и «протекает» на соседний
/// текст.
library;

import 'package:flutter/widgets.dart';

// Через коды, а не сами символы: невидимые управляющие знаки в исходнике
// переставляют текст и в редакторе, и в diff'е, и анализатор о них ругается.
final _lri = String.fromCharCode(0x2066); // LEFT-TO-RIGHT ISOLATE
final _pdi = String.fromCharCode(0x2069); // POP DIRECTIONAL ISOLATE

/// Технические значения (пинг, трафик, адреса, версии, URL) — как есть,
/// слева направо, в любой локали.
String ltrIsolate(String value) => value.isEmpty ? value : '$_lri$value$_pdi';

/// Направление поля ввода для технических значений: адресов, портов, ключей,
/// правил. В персидском интерфейсе поле иначе пишет справа налево, и знак на
/// краю латиницы уезжает на другую сторону: «/path» выглядит как «path/».
const TextDirection technicalInputDirection = TextDirection.ltr;

final _rtlLetter = RegExp('[֐-ࣿיִ-﷿ﹰ-﻿]');
final _letter = RegExp(r'\p{L}', unicode: true);

/// Направление строки, пришедшей извне (имя сервера или подписки), по первой
/// букве — так Android решает для текста без явного направления. Иначе
/// латинское имя в персидском интерфейсе обрезается многоточием не с того
/// края: «…DE | Hyste» вместо «Germany | DE | Hyste…».
TextDirection contentDirection(String text, {required TextDirection fallback}) {
  for (final rune in text.runes) {
    final ch = String.fromCharCode(rune);
    if (_rtlLetter.hasMatch(ch)) return TextDirection.rtl;
    if (_letter.hasMatch(ch)) return TextDirection.ltr;
  }
  return fallback;
}

/// Выравнивание к краю интерфейса, а не к началу самого текста: строка в
/// своём направлении, но у того же края, что и её соседи.
TextAlign uiStartAlign(BuildContext context) =>
    Directionality.of(context) == TextDirection.rtl
        ? TextAlign.right
        : TextAlign.left;

/// Составное техническое значение, разложенное по нескольким виджетам.
///
/// [ltrIsolate] чинит порядок внутри одной строки, но бессилен, когда значение
/// собрано из нескольких `Text` в `Row`: порядок детей задаёт сам `Row` по
/// окружающей `Directionality`. В персидской локали он зеркалится, и
/// `621.8 GiB / 100 GiB` показывается задом наперёд — каждый кусок по
/// отдельности правильный, вместе бессмыслица.
///
/// Меняем только порядок внутри блока, не трогая его место на экране: сам блок
/// обязан остаться у начала строки по правилам локали. Ребёнку нужен
/// `mainAxisSize: MainAxisSize.min`, иначе `Row` растянется на всю ширину и
/// прижмёт содержимое к левому краю.
///
/// Строку-значение этот способ не портит, в отличие от [ltrIsolate] с его
/// невидимыми символами, — для выделяемого и копируемого текста годится только он.
class LtrBlock extends StatelessWidget {
  final Widget child;

  const LtrBlock({super.key, required this.child});

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.ltr,
        child: child,
      );
}
