/// Один замер сервера: когда, сколько и каким методом.
///
/// История нужна автовыбору (см. AutoServerSelect.latencyScore): по одному
/// последнему числу не отличить ровный сервер от того, у кого задержка скачет
/// или кто только что падал. Метод хранится рядом, потому что миллисекунды TCP
/// и HTTP-пинга несравнимы, а у теста скорости в числе вообще кбит/с.
class PingSample {
  const PingSample({required this.at, required this.ms, required this.type});

  /// Сколько замеров помнить. Больше не нужно: оценка смотрит на последние
  /// сутки, а пингуют серверы не чаще раза в несколько минут.
  static const keep = 5;

  /// Методы, которые меряют задержку. Тест скорости кладёт в то же поле кбит/с
  /// (больше — лучше), и в историю задержек ему нельзя.
  static const latencyTypes = {'tcp', 'url', 'icmp'};

  /// [history] с новым замером в конце и без самых старых сверх [keep].
  static List<PingSample> append(List<PingSample> history, PingSample next) {
    final out = [...history, next];
    return out.length > keep ? out.sublist(out.length - keep) : out;
  }

  final DateTime at;

  /// null — замер не удался.
  final int? ms;

  /// Как в ServerItem.lastPingType: `tcp`, `url`, `icmp`.
  final String type;

  /// Списком, а не объектом: история лежит у каждого сервера в общем блобе
  /// настроек, и ключи на каждой записи удваивали бы её вес.
  List<Object?> toJson() => [at.millisecondsSinceEpoch ~/ 1000, ms, type];

  static PingSample? fromJson(Object? raw) {
    if (raw is! List || raw.length != 3) return null;
    final seconds = raw[0];
    final ms = raw[1];
    final type = raw[2];
    if (seconds is! int || (ms != null && ms is! int) || type is! String) {
      return null;
    }
    return PingSample(
      at: DateTime.fromMillisecondsSinceEpoch(seconds * 1000),
      ms: ms as int?,
      type: type,
    );
  }
}
