import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/services/linux_autostart.dart';

void main() {
  test('the autostart entry launches the app with the login flag', () {
    final text = LinuxAutostart.contentFor('/home/u/Apps/keqdroid.AppImage');
    expect(
      text,
      contains('Exec="/home/u/Apps/keqdroid.AppImage" ${LinuxAutostart.flag}\n'),
    );
    expect(text, contains('X-GNOME-Autostart-enabled=true\n'));
    expect(text, startsWith('[Desktop Entry]\n'));
  });

  test('a path with spaces stays one argument', () {
    expect(
      LinuxAutostart.contentFor('/home/u/My Apps/keqdroid'),
      contains('Exec="/home/u/My Apps/keqdroid" --autostart'),
    );
  });
}
