package com.keqdroid.keqdroid

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Как заканчивались прошлые жизни процесса приложения (Android 11+).
 *
 * Жалобу «туннель умер в фоне» иначе не проверить: убитый снаружи процесс
 * ничего не пишет в свои логи, а следующая его жизнь не знает о предыдущей.
 * Система же помнит, кто его убил и почему, вплоть до строки от убийцы
 * прошивки, и отдаёт это самому приложению без разрешений.
 */
object ProcessExits {

    /**
     * Отдать системе статус сессии заранее: он вернётся вместе с записью о
     * смерти процесса. Без него запись не отличает «убили посреди работы
     * VPN» от «убили давно простаивающее приложение».
     */
    fun noteVpnStatus(context: Context, status: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        runCatching {
            context.getSystemService(ActivityManager::class.java)
                ?.setProcessStateSummary("$SUMMARY_PREFIX$status".toByteArray(Charsets.UTF_8))
        }
    }

    /** Последние смерти процесса, от свежей к старой; пусто до Android 11. */
    fun recent(context: Context, max: Int = 10): List<Map<String, Any?>> =
        records(context, max).map { info ->
            mapOf(
                "timestamp" to info.timestamp,
                "reason" to info.reason,
                "reasonName" to reasonName(info.reason),
                "status" to info.status,
                "importance" to info.importance,
                "description" to info.description,
                "vpnStatus" to vpnStatusOf(info),
            )
        }

    /**
     * Прошлая смерть процесса одной строкой — для лога ядра сессии, которую
     * система подняла после неё. Null — записей нет.
     */
    fun describeLast(context: Context): String? {
        val info = records(context, 1).firstOrNull() ?: return null
        val time = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date(info.timestamp))
        val vpn = vpnStatusOf(info)?.let { ", VPN $it" } ?: ""
        val description = info.description?.takeIf { it.isNotBlank() }?.let { ", \"$it\"" } ?: ""
        return "$time, ${reasonName(info.reason)}, status ${info.status}$vpn$description"
    }

    /// Имя константы REASON_* из ApplicationExitInfo: в отчёте и логе число
    /// пришлось бы каждый раз искать по документации.
    private fun reasonName(reason: Int): String = when (reason) {
        ApplicationExitInfo.REASON_EXIT_SELF -> "EXIT_SELF"
        ApplicationExitInfo.REASON_SIGNALED -> "SIGNALED"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "LOW_MEMORY"
        ApplicationExitInfo.REASON_CRASH -> "CRASH"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "CRASH_NATIVE"
        ApplicationExitInfo.REASON_ANR -> "ANR"
        ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "INITIALIZATION_FAILURE"
        ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "PERMISSION_CHANGE"
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "EXCESSIVE_RESOURCE_USAGE"
        ApplicationExitInfo.REASON_USER_REQUESTED -> "USER_REQUESTED"
        ApplicationExitInfo.REASON_USER_STOPPED -> "USER_STOPPED"
        ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "DEPENDENCY_DIED"
        ApplicationExitInfo.REASON_OTHER -> "OTHER"
        ApplicationExitInfo.REASON_FREEZER -> "FREEZER"
        ApplicationExitInfo.REASON_PACKAGE_STATE_CHANGE -> "PACKAGE_STATE_CHANGE"
        ApplicationExitInfo.REASON_PACKAGE_UPDATED -> "PACKAGE_UPDATED"
        else -> "UNKNOWN($reason)"
    }

    private fun records(context: Context, max: Int): List<ApplicationExitInfo> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return emptyList()
        val am = context.getSystemService(ActivityManager::class.java) ?: return emptyList()
        return runCatching {
            am.getHistoricalProcessExitReasons(context.packageName, 0, max)
        }.getOrDefault(emptyList())
    }

    private fun vpnStatusOf(info: ApplicationExitInfo): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        val raw = info.processStateSummary?.toString(Charsets.UTF_8) ?: return null
        return raw.removePrefix(SUMMARY_PREFIX).takeIf { raw.startsWith(SUMMARY_PREFIX) }
    }

    private const val SUMMARY_PREFIX = "vpn="
}
