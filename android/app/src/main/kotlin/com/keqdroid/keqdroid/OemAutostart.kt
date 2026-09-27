package com.keqdroid.keqdroid

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings

/**
 * Экран «Автозапуска» прошивки — разрешения, которого нет в Android, а потому
 * нет и в его списке разрешений.
 *
 * На прошивках с ним выключенный автозапуск запрещает поднимать сервис из
 * шторки и после убийства процесса, хотя всё, что спрашивает Android, выдано.
 * Состояние его снаружи не прочитать, а экран каждая прошивка прячет под своим
 * именем. Экраны — из библиотеки AutoStarter (ею пользуется Happ); realme она
 * не знает, хотя прошивка у него та же ColorOS, что у OPPO.
 */
object OemAutostart {

    private class Vendor(val brands: Set<String>, val screens: List<ComponentName>)

    private val vendors = listOf(
        Vendor(
            setOf("xiaomi", "redmi", "poco"),
            listOf(
                ComponentName(
                    "com.miui.securitycenter",
                    "com.miui.permcenter.autostart.AutoStartManagementActivity",
                ),
            ),
        ),
        // На свежих ColorOS и realme UI автозапуск переехал в управление
        // батареей приложения (dontkillmyapp), а старые экраны менеджера
        // запуска чужим часто закрыты. Тогда открываем карточку приложения —
        // ближайшее к переключателю место, куда пускают.
        Vendor(
            setOf("oppo", "realme", "oneplus"),
            listOf(
                ComponentName(
                    "com.coloros.safecenter",
                    "com.coloros.safecenter.permission.startup.StartupAppListActivity",
                ),
                ComponentName(
                    "com.coloros.safecenter",
                    "com.coloros.safecenter.startupapp.StartupAppListActivity",
                ),
                ComponentName(
                    "com.oppo.safe",
                    "com.oppo.safe.permission.startup.StartupAppListActivity",
                ),
                ComponentName(
                    "com.oneplus.security",
                    "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity",
                ),
            ),
        ),
        Vendor(
            setOf("vivo", "iqoo"),
            listOf(
                ComponentName(
                    "com.iqoo.secure",
                    "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity",
                ),
                ComponentName(
                    "com.vivo.permissionmanager",
                    "com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
                ),
                ComponentName(
                    "com.iqoo.secure",
                    "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager",
                ),
            ),
        ),
        Vendor(
            setOf("huawei", "honor"),
            listOf(
                ComponentName(
                    "com.huawei.systemmanager",
                    "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
                ),
                ComponentName(
                    "com.huawei.systemmanager",
                    "com.huawei.systemmanager.optimize.process.ProtectActivity",
                ),
            ),
        ),
        Vendor(
            setOf("asus"),
            listOf(
                ComponentName(
                    "com.asus.mobilemanager",
                    "com.asus.mobilemanager.autostart.AutoStartActivity",
                ),
            ),
        ),
    )

    const val KIND_NONE = "none"
    const val KIND_SCREEN = "screen"
    const val KIND_APP_DETAILS = "appDetails"

    private fun vendor(): Vendor? {
        val names = setOf(Build.BRAND.lowercase(), Build.MANUFACTURER.lowercase())
        return vendors.firstOrNull { v -> v.brands.any { it in names } }
    }

    /// Экраны прошивки, которые на этом телефоне реально откроются.
    /// Неэкспортированный резолвится, но вместо окна даёт SecurityException.
    private fun screens(context: Context): List<Intent> =
        vendor()?.screens.orEmpty().mapNotNull { screen ->
            val intent = Intent().setComponent(screen).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            val info = runCatching { context.packageManager.resolveActivity(intent, 0) }.getOrNull()
            intent.takeIf { info?.activityInfo?.exported == true }
        }

    /**
     * Куда поведёт строка: [KIND_NONE] — автозапуска у прошивки нет, строка
     * не нужна; [KIND_SCREEN] — прямо в его экран; [KIND_APP_DETAILS] — в
     * карточку приложения, где искать придётся самому, и об этом надо
     * сказать до перехода: вернувшись, человек подсказку уже не увидит.
     */
    fun kind(context: Context): String = when {
        vendor() == null -> KIND_NONE
        screens(context).isNotEmpty() -> KIND_SCREEN
        else -> KIND_APP_DETAILS
    }

    fun open(context: Context) {
        for (intent in screens(context)) {
            if (runCatching { context.startActivity(intent) }.isSuccess) return
        }
        context.startActivity(
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", context.packageName, null),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }
}
