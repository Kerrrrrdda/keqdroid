import '../models/ping_sample.dart';
import '../models/server_item.dart';

/// Выбор сервера за человека — та самая «Авто» в шапке подписки.
///
/// Правило одно: из живых берём лучший по замерам ([latencyScore]). Живой тут
/// значит «последний замер удался»: [ServerItem.pingMs] у неудачного замера
/// обнуляется (см. servers_provider), поэтому красный сервер и сервер, которого
/// никогда не мерили, в списке выглядят одинаково — и это не одно и то же. Ни
/// разу не меренный не мёртв, он неизвестен, поэтому идёт следом за
/// померенными, а не выбрасывается: подписка, которую ещё не пинговали, иначе
/// не дала бы подключиться вовсе.
abstract final class AutoServerSelect {
  /// За какой срок замеры ещё что-то говорят о сервере.
  static const historyWindow = Duration(hours: 24);

  /// Цена одного провала за сутки в оценке — больше любой живой задержки:
  /// сервер, который недавно падал, идёт после ровных.
  static const failurePenalty = 1000;

  /// Оценка по задержке, меньше — лучше; null — по задержке судить нечем
  /// (последний замер провален или это тест скорости).
  ///
  /// Типичная задержка (медиана), плюс разброс, плюс штраф за каждый провал:
  /// сервер, у которого пинг то 80, то 400, проигрывает ровным 150. Считаются
  /// только замеры тем же методом, что и последний, — миллисекунды TCP и
  /// HTTP-пинга между собой несравнимы. Без истории оценка — последний замер.
  static int? latencyScore(ServerItem server, DateTime now) {
    final last = server.pingMs;
    final type = server.lastPingType;
    if (last == null) return null;
    if (type != null && !PingSample.latencyTypes.contains(type)) return null;
    final recent = [
      for (final s in server.pingSamples)
        if (s.type == type && now.difference(s.at).abs() <= historyWindow) s,
    ];
    final answered = [
      for (final s in recent)
        if (s.ms != null) s.ms!,
    ]..sort();
    final failures = recent.length - answered.length;
    if (answered.length < 2) return last + failures * failurePenalty;
    final median = answered[answered.length ~/ 2];
    final spread = answered.last - answered.first;
    return median + spread + failures * failurePenalty;
  }

  /// Скорость из теста скорости, кбит/с; null — сервер мерили не им.
  static int? _speedKbps(ServerItem server) =>
      server.lastPingType == 'speed' ? server.pingMs : null;

  /// Порядок «кто лучше» для [pick] и [candidatesToMeasure]: сначала
  /// оценённые по задержке, затем живые по тесту скорости (быстрые первыми),
  /// затем не меренные, последними — с проваленным замером.
  static List<ServerItem> _ranked(Iterable<ServerItem> servers, DateTime now) {
    int tier(ServerItem s) {
      if (latencyScore(s, now) != null) return 0;
      if (_speedKbps(s) != null) return 1;
      if (s.lastTestedAt == null) return 2;
      return 3;
    }

    // Сортировка в Dart не устойчивая, а при равенстве первым должен остаться
    // тот, кто раньше в списке, — поэтому порядок в списке последний ключ.
    final indexed = servers.indexed.toList();
    indexed.sort((x, y) {
      final (ia, a) = x;
      final (ib, b) = y;
      final byTier = tier(a).compareTo(tier(b));
      if (byTier != 0) return byTier;
      final byValue = switch (tier(a)) {
        0 => latencyScore(a, now)!.compareTo(latencyScore(b, now)!),
        1 => _speedKbps(b)!.compareTo(_speedKbps(a)!),
        _ => 0,
      };
      return byValue != 0 ? byValue : ia.compareTo(ib);
    });
    return [for (final (_, s) in indexed) s];
  }

  /// Кого включать автовыбором в подписке [subscriptionId].
  ///
  /// [exclude] — сервер, с которого только что съехали: он только что не
  /// работал, и возвращаться на него в ту же секунду незачем. Когда кроме
  /// него никого нет, возвращаем его же — «совсем ничего» и «единственный
  /// сервер» разные вещи, и во втором случае честнее попробовать ещё раз.
  ///
  /// [excludeHost] — адрес умершего сервера. Протоколы на одной машине
  /// умирают вместе (на живом тесте погасили VPS, и в списке остался его же
  /// Vless со старым хорошим пингом), так что соседей по адресу обходим
  /// тоже — пока есть кто-то ещё.
  static ServerItem? pick(
    List<ServerItem> servers, {
    required String subscriptionId,
    String? exclude,
    String? excludeHost,
    DateTime? now,
  }) {
    final group = [
      for (final server in servers)
        if (server.subscriptionId == subscriptionId) server,
    ];
    if (group.isEmpty) return null;

    final host = excludeHost?.trim().toLowerCase();
    final elsewhere = [
      for (final server in group)
        if (server.id != exclude &&
            (host == null ||
                host.isEmpty ||
                server.address.trim().toLowerCase() != host))
          server,
    ];
    final candidates = elsewhere.isNotEmpty
        ? elsewhere
        : [
            for (final server in group)
              if (server.id != exclude) server,
          ];
    final pool = candidates.isEmpty ? group : candidates;

    // Если остались только те, чей замер не удался, всё равно берём первого:
    // замер мог не удаться и по своей причине (пинг шёл до подключения, сеть
    // сменилась), а «автовыбор ничего не выбрал» — худший из возможных
    // ответов на нажатую кнопку.
    return _ranked(pool, now ?? DateTime.now()).first;
  }

  /// Кого мерить, когда текущий сервер под подозрением: он сам и лучшие из
  /// соседей по подписке — всего не больше [limit].
  ///
  /// Сам текущий — обязательно: решение «уходить» принимается по его же
  /// свежему замеру, а не по тому, что показалось сторожу. Соседей — по
  /// порядку старых замеров, потому что мерить всю подписку ради одного
  /// переезда незачем, а десяток на Android — это ровно одно ядро замера.
  ///
  /// [include] — кого мерить обязательно, сразу после текущего: «свой» сервер
  /// автовыбора, на который ждём возможности вернуться (см. AutoSelectHome).
  static List<ServerItem> candidatesToMeasure(
    List<ServerItem> servers, {
    required String subscriptionId,
    required ServerItem current,
    int limit = 10,
    Set<String> include = const {},
    DateTime? now,
  }) {
    final group = [
      for (final server in servers)
        if (server.subscriptionId == subscriptionId && server.id != current.id)
          server,
    ];
    final forced = [
      for (final server in group)
        if (include.contains(server.id)) server,
    ];
    final others = _ranked(
      group.where((s) => !include.contains(s.id)),
      now ?? DateTime.now(),
    );
    return [current, ...forced, ...others].take(limit).toList();
  }

  /// Что делать по замеру — полному или ещё идущему.
  ///
  /// Правила, и все по результатам, а не по догадкам:
  ///
  /// текущий ответил — остаёмся, тревога была ложной, что бы её ни вызвало;
  /// текущий не ответил, а кто-то из соседей ответил — переезжаем на самого
  /// быстрого из ответивших, то есть на сервер, живой прямо сейчас, а не
  /// когда-то в прошлом замере;
  /// не ответил никто — остаёмся: это либо сеть, либо всё мёртвое сразу, и
  /// переезд ничего бы не дал.
  ///
  /// Пока своего ответа у текущего нет, соседи ничего не решают, сколько бы
  /// их ни ответило: результаты приходят по мере готовности, и сервер, который
  /// просто дальше соседей, иначе проигрывал бы гонку и покидался живым.
  /// Пробы стартуют разом, поэтому первый ответивший и есть самый быстрый.
  static AutoSelectVerdict judge({
    required String currentId,
    required Iterable<({String id, bool success, int? latencyMs})> results,
    required bool batchComplete,
  }) {
    ({String id, bool success, int? latencyMs})? current;
    ({String id, bool success, int? latencyMs})? best;
    for (final r in results) {
      if (r.id == currentId) {
        current = r;
        continue;
      }
      if (!r.success) continue;
      if (best == null || (r.latencyMs ?? 1 << 30) < (best.latencyMs ?? 1 << 30)) {
        best = r;
      }
    }
    if (current != null && current.success) return const AutoSelectVerdict.stay();
    if (current != null && best != null) return AutoSelectVerdict.switchTo(best.id);
    return batchComplete
        ? const AutoSelectVerdict.stay()
        : const AutoSelectVerdict.undecided();
  }
}

/// Итог [AutoServerSelect.judge].
final class AutoSelectVerdict {
  const AutoSelectVerdict.stay() : nextId = null, decided = true;
  const AutoSelectVerdict.switchTo(String this.nextId) : decided = true;
  const AutoSelectVerdict.undecided() : nextId = null, decided = false;

  /// Куда переезжать; null — оставаться (или ещё не решено).
  final String? nextId;

  /// false — замер ещё идёт, и по уже пришедшему решать рано.
  final bool decided;
}
