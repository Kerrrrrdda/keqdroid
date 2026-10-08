import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/services/linux_firewall.dart';

void main() {
  test('ufw counts as on only with ENABLED=yes', () {
    expect(LinuxFirewalls.ufwEnabled('# comment\nENABLED=yes\n'), isTrue);
    expect(LinuxFirewalls.ufwEnabled('ENABLED="yes"'), isTrue);
    expect(LinuxFirewalls.ufwEnabled('ENABLED=no\n'), isFalse);
    expect(LinuxFirewalls.ufwEnabled('#ENABLED=yes'), isFalse);
  });

  test('the command opens every shared port', () {
    expect(
      LinuxFirewalls.openCommand(LinuxFirewall.firewalld, [2080, 2081]),
      'sudo firewall-cmd --permanent --add-port=2080/tcp --add-port=2081/tcp '
      '&& sudo firewall-cmd --reload',
    );
    expect(
      LinuxFirewalls.openCommand(LinuxFirewall.ufw, [2080, 2081]),
      'sudo ufw allow 2080/tcp && sudo ufw allow 2081/tcp',
    );
  });
}
