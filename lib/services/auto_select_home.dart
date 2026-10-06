import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// «Свой» сервер автовыбора: тот, с которого увёз аварийный переезд.
///
/// Автовыбор уходит с сервера, только когда тот не ответил, и уходит на
/// первого живого соседа — не на лучшего вообще, а на того, кто ответил в эту
/// секунду. Когда свой сервер оживает, на него возвращаемся. Только после
/// нескольких удачных проверок подряд ([returnAfter]): возврат рвёт открытые
/// соединения, и прыгать туда-сюда за сервером, который мигает, хуже, чем
/// посидеть на соседе.
///
/// Цепочка переездов свой сервер не меняет: упал и сосед — едем к третьему, а
/// ждать по-прежнему первого. Сбрасывается он, когда сервер выбрал не
/// автовыбор: человек ткнул руками, включил «Авто» заново, подписка сменилась.
class AutoSelectHome {
  const AutoSelectHome({
    required this.subscriptionId,
    required this.homeId,
    required this.pickedId,
    this.aliveStreak = 0,
  });

  /// Сколько проверок подряд свой сервер должен ответить, чтобы вернуться.
  static const returnAfter = 2;

  final String subscriptionId;

  /// Куда вернуться.
  final String homeId;

  /// Куда увёз последний аварийный переезд. Активный сервер не он и не свой —
  /// значит, сервер сменил кто-то другой, и ждать больше нечего.
  final String pickedId;

  /// Сколько проверок подряд свой сервер отвечает.
  final int aliveStreak;

  bool get shouldReturn => aliveStreak >= returnAfter;

  /// Состояние после аварийного переезда с [fromId] на [toId].
  static AutoSelectHome afterFailover(
    AutoSelectHome? previous, {
    required String subscriptionId,
    required String fromId,
    required String toId,
  }) {
    final keep = previous != null &&
        previous.subscriptionId == subscriptionId &&
        previous.pickedId == fromId &&
        previous.homeId != toId;
    return AutoSelectHome(
      subscriptionId: subscriptionId,
      homeId: keep ? previous.homeId : fromId,
      pickedId: toId,
    );
  }

  /// Ждать ли ещё своего сервера при активном [activeId], когда «Авто» горит в
  /// подписке [autoSubscriptionId] (null — нигде), а [homeExists] — остался ли
  /// свой сервер в списке. null — сбросить.
  AutoSelectHome? stillWaiting({
    required String activeId,
    required String? autoSubscriptionId,
    required bool homeExists,
  }) {
    if (autoSubscriptionId != subscriptionId) return null;
    if (!homeExists) return null;
    if (activeId != pickedId) return null;
    return this;
  }

  /// Итог очередной проверки своего сервера: ответил он или нет.
  AutoSelectHome afterCheck({required bool homeAnswered}) => AutoSelectHome(
        subscriptionId: subscriptionId,
        homeId: homeId,
        pickedId: pickedId,
        aliveStreak: homeAnswered ? aliveStreak + 1 : 0,
      );

  Map<String, Object> toJson() => {
        'sub': subscriptionId,
        'home': homeId,
        'picked': pickedId,
        'streak': aliveStreak,
      };

  static AutoSelectHome? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final sub = raw['sub'];
    final home = raw['home'];
    final picked = raw['picked'];
    if (sub is! String || home is! String || picked is! String) return null;
    final streak = raw['streak'];
    return AutoSelectHome(
      subscriptionId: sub,
      homeId: home,
      pickedId: picked,
      aliveStreak: streak is int ? streak : 0,
    );
  }
}

/// Где свой сервер живёт между запусками. На диске, а не в памяти: на Android
/// интерфейс приложения система выгружает, пока туннель работает дальше, и
/// после этого вернуться было бы некуда.
abstract final class AutoSelectHomeStore {
  static const _key = 'auto_select_home';

  static Future<AutoSelectHome?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return null;
    try {
      return AutoSelectHome.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(AutoSelectHome? home) async {
    final prefs = await SharedPreferences.getInstance();
    if (home == null) {
      await prefs.remove(_key);
    } else {
      await prefs.setString(_key, jsonEncode(home.toJson()));
    }
  }
}
