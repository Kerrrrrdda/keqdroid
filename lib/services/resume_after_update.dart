import 'package:shared_preferences/shared_preferences.dart';

/// Метка «туннель был включён, когда приложение ушло ставить обновление».
///
/// На ПК сессию перед перезапуском на обновление гасим сами: ядро держит файлы,
/// которые апдейтер перезаписывает. Без метки новый процесс не знал, что
/// подключение было, и после обновления VPN оказывался выключенным.
class ResumeAfterUpdate {
  ResumeAfterUpdate._();

  static const _key = 'resume_vpn_after_update_at';

  /// Перезапуск с копированием файлов и окном UAC укладывается в минуты. Метка
  /// старше значит, что обновление сорвалось, и подключаться при ручном запуске
  /// через полдня было бы неожиданно.
  static const maxAge = Duration(minutes: 30);

  static Future<void> mark({DateTime? now}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_key, (now ?? DateTime.now()).millisecondsSinceEpoch);
  }

  /// Забирает метку: `true`, если она была и свежая. Читается один раз, так
  /// что следующий запуск уже обычный.
  static Future<bool> take({DateTime? now}) async {
    final prefs = await SharedPreferences.getInstance();
    final at = prefs.getInt(_key);
    if (at == null) return false;
    await prefs.remove(_key);
    final age = (now ?? DateTime.now()).difference(
      DateTime.fromMillisecondsSinceEpoch(at),
    );
    // abs: синхронизация могла подвести часы назад между двумя запусками.
    return age.abs() <= maxAge;
  }
}
