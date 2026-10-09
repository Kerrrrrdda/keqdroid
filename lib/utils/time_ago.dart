import '../l10n/app_localizations.dart';

/// Давность одной меркой на всё приложение: «только что», «5м назад», «3ч
/// назад», «2д назад». Так пишется обновление подписки и списка по ссылке.
String timeAgo(AppLocalizations l10n, DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 1) return l10n.subscriptionsJustNow;
  if (diff.inHours < 1) return l10n.subscriptionsMinutesAgo(diff.inMinutes);
  if (diff.inDays < 1) return l10n.subscriptionsHoursAgo(diff.inHours);
  return l10n.subscriptionsDaysAgo(diff.inDays);
}
