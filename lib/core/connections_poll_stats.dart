/// Что стоят приложению опросы `GET /connections` у ядра — для слепков памяти
/// в журнале (см. MemoryWatch).
///
/// Главный подозреваемый в утечке после сна на Windows (20 ГБ у самого
/// keqdroid.exe, ядра ни при чём): счётчики трафика спрашивают ядро раз в
/// секунду и не ждут прошлого ответа, а ответ — это весь список соединений,
/// который приложение разбирает целиком. Если ядро после пробуждения перестаёт
/// закрывать соединения, ответ растёт, а зависшие запросы копятся. Эти числа
/// в журнале подтвердят или снимут подозрение.
class ConnectionsPollStats {
  ConnectionsPollStats._();

  static final instance = ConnectionsPollStats._();

  int _inFlight = 0;
  int _maxInFlight = 0;
  int _requests = 0;
  int _failures = 0;
  int _slow = 0;
  int _maxBodyChars = 0;
  int _maxConnections = 0;

  /// Дольше этого ответ уже странен: ядро на петле отвечает за миллисекунды.
  static const slowAfter = Duration(seconds: 1);

  /// Запрос пошёл. Возвращает отметку для [end].
  Stopwatch begin() {
    _inFlight++;
    _requests++;
    if (_inFlight > _maxInFlight) _maxInFlight = _inFlight;
    return Stopwatch()..start();
  }

  /// Запрос закончился — ответом [bodyChars] символов с [connections]
  /// соединениями или неудачей ([ok] = false).
  void end(Stopwatch started, {bool ok = true, int bodyChars = 0, int? connections}) {
    _inFlight--;
    if (!ok) _failures++;
    if (started.elapsed > slowAfter) _slow++;
    if (bodyChars > _maxBodyChars) _maxBodyChars = bodyChars;
    if (connections != null && connections > _maxConnections) {
      _maxConnections = connections;
    }
  }

  int get inFlight => _inFlight;

  /// Сводка с прошлого вызова; максимумы после неё начинаются заново, а
  /// «сейчас в полёте» — нет: это состояние, а не счёт за период.
  String takeSummary() {
    final summary = '$_requests requests, in flight $_inFlight '
        '(max $_maxInFlight), failed $_failures, slow $_slow, '
        'largest ${_kb(_maxBodyChars)} / $_maxConnections connections';
    _requests = 0;
    _failures = 0;
    _slow = 0;
    _maxInFlight = _inFlight;
    _maxBodyChars = 0;
    _maxConnections = 0;
    return summary;
  }

  static String _kb(int chars) =>
      chars < 1024 ? '$chars B' : '${(chars / 1024).round()} KB';
}
