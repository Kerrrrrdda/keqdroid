import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/services/linux_desktop_entry.dart';

void main() {
  group('contentFor', () {
    const appImage = '/home/u/Apps/keqdroid-0.25.2-x86_64.AppImage';

    test('ties the window to the entry by the app id', () {
      final text = LinuxDesktopEntry.contentFor(appImage, hidden: false);
      expect(text, contains('StartupWMClass=com.keqdroid.keqdroid\n'));
      expect(text, contains('Exec="$appImage"\n'));
      expect(text, contains('TryExec=$appImage\n'));
      expect(text, contains(LinuxDesktopEntry.marker));
      expect(text, isNot(contains('NoDisplay')));
    });

    test('stays out of the menu when another entry already launches it', () {
      final text = LinuxDesktopEntry.contentFor(appImage, hidden: true);
      expect(text, contains('NoDisplay=true\n'));
    });
  });

  group('execArgument', () {
    test('quotes a path with spaces', () {
      expect(
        LinuxDesktopEntry.execArgument('/home/u/My Apps/k.AppImage'),
        '"/home/u/My Apps/k.AppImage"',
      );
    });

    test('escapes reserved characters twice, as the spec requires', () {
      // Кавычка, доллар и обратный апостроф экранируются для кавычек, а
      // получившийся обратный слеш — ещё раз как строковое значение ключа.
      expect(LinuxDesktopEntry.execArgument(r'/a"b$c`d'), r'"/a\\"b\\$c\\`d"');
      expect(LinuxDesktopEntry.execArgument(r'/a\b'), r'"/a\\\\b"');
      expect(LinuxDesktopEntry.execArgument('/100%/k'), '"/100%%/k"');
    });
  });

  test('integratedElsewhere spots an AppImageLauncher or Gear Lever entry', () {
    const appImage = '/home/u/Applications/keqdroid.AppImage';
    expect(
      LinuxDesktopEntry.integratedElsewhere(appImage, [
        '[Desktop Entry]\nExec=/usr/bin/firefox\n',
        '[Desktop Entry]\nExec="$appImage" %U\n',
      ]),
      isTrue,
    );
    expect(
      LinuxDesktopEntry.integratedElsewhere(appImage, [
        '[Desktop Entry]\nExec=/usr/bin/firefox\n',
      ]),
      isFalse,
    );
  });
}
