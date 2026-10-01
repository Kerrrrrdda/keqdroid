import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/services/resume_after_update.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final marked = DateTime(2026, 10, 1, 12);

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('без метки обычный запуск', () async {
    expect(await ResumeAfterUpdate.take(now: marked), isFalse);
  });

  test('свежая метка поднимает туннель ровно один раз', () async {
    await ResumeAfterUpdate.mark(now: marked);

    final later = marked.add(const Duration(minutes: 2));
    expect(await ResumeAfterUpdate.take(now: later), isTrue);
    expect(await ResumeAfterUpdate.take(now: later), isFalse);
  });

  test('протухшая метка не подключает и снимается', () async {
    await ResumeAfterUpdate.mark(now: marked);

    final muchLater = marked.add(
      ResumeAfterUpdate.maxAge + const Duration(minutes: 1),
    );
    expect(await ResumeAfterUpdate.take(now: muchLater), isFalse);
    expect(await ResumeAfterUpdate.take(now: marked), isFalse);
  });

  test('часы, подведённые назад, метку не губят', () async {
    await ResumeAfterUpdate.mark(now: marked);

    final earlier = marked.subtract(const Duration(seconds: 30));
    expect(await ResumeAfterUpdate.take(now: earlier), isTrue);
  });
}
