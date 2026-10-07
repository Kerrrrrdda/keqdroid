import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/tunnel/linux_tunnel_backend.dart';

/// Беспарольный TUN держится на строках, которые живут в трёх местах: теле
/// обёртки, правиле polkit и проверке «установлено ли». Разойдись они — и
/// правило разрешало бы не тот файл, хелпер не узнавал бы сам себя, а старый
/// хелпер, запускавший от root что угодно, не снимался бы.
void main() {
  final body = LinuxTunnelBackend.tunWrapperBodyForTest;
  const helper = LinuxTunnelBackend.polkitHelperPathForTest;
  const mark = LinuxTunnelBackend.helperVersionMarkForTest;

  test('the wrapper knows its own installed path', () {
    expect(body, contains('HELPER=$helper\n'));
  });

  test('the polkit rule allows exactly that path', () {
    expect(
      LinuxTunnelBackend.polkitRuleForTest,
      contains('action.lookup("program") == "$helper"'),
    );
  });

  test('an installed helper carries the mark the app looks for', () {
    // Хелпер — это shebang плюс то же тело.
    expect(body, contains(mark));
    // И снимается только хелпер без этой метки.
    expect(body, contains("grep -q '\\$mark'"));
  });

  test('without a password only the trusted copy of the core runs', () {
    expect(body, contains('|| exit 4'));
    expect(body, contains(r'SB="$CORES/$NAME"'));
  });
}
