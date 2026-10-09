import 'dart:io' show Platform;
import 'dart:math' as math;

/// Запись сплита с путём — «только этот файл», без пути — «любая программа
/// с таким именем». Путь записывается, только когда его указали вручную
/// (вписали или выбрали через «Обзор…»); отметка в списке пишет имя, чтобы
/// программа, обновившаяся в новую папку, не выпадала из сплита.
bool isProcessPathEntry(String raw) =>
    raw.contains(r'\') || raw.contains('/');

/// Путь из записи сплита: без кавычек и пробелов по краям, на Windows — с
/// обратными косыми, как их отдаёт система.
String normalizeProcessPath(String raw, {bool? windows}) {
  final s = raw.trim().replaceAll('"', '');
  return (windows ?? Platform.isWindows) ? s.replaceAll('/', r'\') : s;
}

/// нормализует ввод/путь к имени процесса для sing-box (например `Telegram.exe`).
/// регистр важен: sing-box сравнивает process_name через map-lookup без
/// приведения к нижнему регистру, так что сравнение чувствительно к регистру.
/// на windows имя процесса хранит реальный регистр (`Telegram.exe`), и если
/// его занизить — правило не совпадёт и трафик уйдёт мимо прокси.
///
/// `.exe` дописывается только на Windows: на Linux имя процесса — имя файла
/// как есть (`firefox`), и с суффиксом правило не совпадало ни разу.
String normalizeProcessName(String raw, {bool? windows}) {
  var s = raw.trim();
  if (s.isEmpty) return '';
  s = s.replaceAll('"', '');
  final cut = math.max(s.lastIndexOf(r'\'), s.lastIndexOf('/'));
  if (cut >= 0) {
    // Отрезаем по обоим разделителям, а не средствами `path`.
    //
    // `p.basename` работает в стиле текущей платформы, а имя сюда может
    // приехать с чужой: список сплит-туннелирования переносится между машинами
    // через резервную копию настроек. На Linux `\` разделителем не считается, и
    // виндовый путь возвращался целиком — запись «C:\...\Discord.exe» переставала
    // схлопываться с «Discord.exe» и превращалась во второе приложение в списке.
    s = s.substring(cut + 1);
  }
  if ((windows ?? Platform.isWindows) && !s.toLowerCase().endsWith('.exe')) {
    s = '$s.exe';
  }
  return s;
}

/// варианты имени для правил sing-box: исходный регистр и, если отличается,
/// нижний — на случай значений, сохранённых старой версией в нижнем регистре.
List<String> processNameMatchVariants(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return const [];
  final lower = trimmed.toLowerCase();
  return trimmed == lower ? [trimmed] : [trimmed, lower];
}

/// Строка буквально, внутри регулярного выражения ядра.
///
/// Всё, кроме латиницы и цифр, пишется кодом `\xNN`: его одинаково понимают
/// regexp2 у mihomo и RE2 у sing-box, а точка иначе значила бы «любой
/// символ». mihomo к тому же режет правило по запятым и считает скобки в
/// логических правилах — закодированные они ему не мешают.
String processRegexLiteral(String text) {
  final out = StringBuffer();
  for (final rune in text.runes) {
    final isAsciiAlnum = (rune >= 0x30 && rune <= 0x39) ||
        (rune >= 0x41 && rune <= 0x5a) ||
        (rune >= 0x61 && rune <= 0x7a);
    if (isAsciiAlnum || rune > 0x7f) {
      out.writeCharCode(rune);
    } else {
      out.write('\\x${rune.toRadixString(16).padLeft(2, '0')}');
    }
  }
  return out.toString();
}

/// Путь к программе как регулярка: разделитель совпадает с любой косой, так
/// что `C:/Apps/a.exe`, вписанный руками, ловит и `C:\Apps\a.exe` системы.
String processPathPattern(String path) =>
    path.split(RegExp(r'[\\/]')).map(processRegexLiteral).join(r'[\x5c/]');
