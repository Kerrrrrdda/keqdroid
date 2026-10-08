import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// Межсетевой экран Linux, который может не пустить к раздаче в сети.
///
/// Открыть порт сами мы не можем — нужен root, — а без этого раздача молча
/// не работает: другие устройства просто не подключаются. Поэтому только
/// узнаём, какой экран включён, и подсказываем команду.
enum LinuxFirewall { firewalld, ufw }

class LinuxFirewalls {
  LinuxFirewalls._();

  /// Включённый экран или null. firewalld спрашиваем через `firewall-cmd
  /// --state`, ему root не нужен; у ufw `ufw status` требует root, поэтому
  /// читаем его конфиг, открытый всем.
  static Future<LinuxFirewall?> detect() async {
    try {
      final r = await Process.run('firewall-cmd', ['--state']);
      if (r.exitCode == 0 && '${r.stdout}'.trim() == 'running') {
        return LinuxFirewall.firewalld;
      }
    } on ProcessException {
      // firewalld не установлен
    }
    try {
      final conf = await File('/etc/ufw/ufw.conf').readAsString();
      if (ufwEnabled(conf)) return LinuxFirewall.ufw;
    } catch (_) {}
    return null;
  }

  @visibleForTesting
  static bool ufwEnabled(String conf) => conf
      .split('\n')
      .map((l) => l.trim().replaceAll('"', '').replaceAll("'", ''))
      .any((l) => l.toLowerCase() == 'enabled=yes');

  /// Команда, открывающая [ports] насовсем.
  static String openCommand(LinuxFirewall firewall, List<int> ports) =>
      switch (firewall) {
        LinuxFirewall.firewalld =>
          'sudo firewall-cmd --permanent '
              '${ports.map((p) => '--add-port=$p/tcp').join(' ')} '
              '&& sudo firewall-cmd --reload',
        LinuxFirewall.ufw =>
          ports.map((p) => 'sudo ufw allow $p/tcp').join(' && '),
      };
}
