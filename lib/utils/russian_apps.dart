/// Приложения российских сервисов — для кнопки «русские приложения мимо VPN»
/// в сплит-туннелинге.
///
/// Решение только по имени пакета. Название приложения не годится: на
/// телефоне с русским языком системные приложения и чужие программы тоже
/// подписаны кириллицей, и прежняя проверка по ней отмечала полтелефона.
library;

/// Пакеты российских сервисов, которые не начинаются с `ru.`: у разработчика
/// международный домен (`com.`), и по имени их не узнать. За каждым префиксом
/// стоит найденное в Google Play или RuStore приложение (26.09.2026); префикс,
/// за которым ничего не нашлось, зацепил бы разве что чужое, поэтому
/// пополнять так же, не по памяти.
const _companyPrefixes = <String>[
  'com.yandex.',
  'com.vkontakte.',
  'com.vk.',
  'com.avito.',
  'com.idamob.tinkoff.',
  'com.wildberries.',
  'com.lamoda.',
  'com.kaspersky.',
  'com.kms.',
  'com.drweb.',
  'com.citymobil.',
  'com.taxsee.',
  'com.icemobile.lenta.',
  'com.ncloudtech.',
  'gpm.tnt_premier',
];

/// Пакеты, которые сами по себе и есть приложение, без хвоста после точки:
/// префикс `com.drweb.` такой пакет не ловит.
const _exactPackages = <String>{
  'com.drweb',
  'com.citymobil',
  'com.deliveryclub',
  'com.punicapp.whoosh',
};

/// Приложение российского сервиса.
///
/// Три признака, от надёжного к осторожному:
/// явный список выше; первая метка `ru` или `su` — перевёрнутый домен
/// разработчика в зоне .ru/.su; последняя метка `ru` (`com.wildberries.ru`) —
/// только у несистемных приложений. Системным приложениям остаются первые
/// два: производитель телефона вполне может назвать региональную сборку своей
/// программы с `.ru` на конце, а российские предустановки (RuStore, Яндекс,
/// операторы) и так начинаются с `ru.` или есть в списке.
bool isRussianApp(String packageName, {required bool isSystem}) {
  final pkg = packageName.trim().toLowerCase();
  if (pkg.isEmpty) return false;
  if (_exactPackages.contains(pkg)) return true;
  if (_companyPrefixes.any(pkg.startsWith)) return true;

  final labels = pkg.split('.');
  if (labels.length < 2) return false;
  if (labels.first == 'ru' || labels.first == 'su') return true;
  return !isSystem && labels.length > 2 && labels.last == 'ru';
}
