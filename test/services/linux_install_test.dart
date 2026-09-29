import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/services/linux_install.dart';

void main() {
  const exe = '/opt/keqdroid/keqdroid';

  Future<LinuxInstallKind> classify({
    String? appImage,
    String? owner,
    bool writable = true,
  }) {
    return LinuxInstall.classify(
      appImagePath: appImage,
      executable: exe,
      owns: (tool, args) async {
        // Спрашивают про сам исполняемый файл, а не про имя пакета.
        expect(args.last, exe);
        return tool == owner;
      },
      writable: (dir) {
        expect(dir, '/opt/keqdroid');
        return writable;
      },
    );
  }

  test('AppImage узнаётся по переменной рантайма, менеджеры не спрашиваются',
      () async {
    expect(
      await classify(appImage: '/home/u/keqdroid.AppImage', owner: 'dpkg-query'),
      LinuxInstallKind.appImage,
    );
  });

  test('пакет узнаётся по тому, какой менеджер владеет файлом', () async {
    expect(await classify(owner: 'dpkg-query'), LinuxInstallKind.deb);
    expect(await classify(owner: 'rpm'), LinuxInstallKind.rpm);
    expect(await classify(owner: 'pacman'), LinuxInstallKind.pacman);
  });

  test('ничей файл — распакованный архив; без записи — только для чтения',
      () async {
    expect(await classify(), LinuxInstallKind.portable);
    expect(await classify(writable: false), LinuxInstallKind.readOnly);
  });
}
