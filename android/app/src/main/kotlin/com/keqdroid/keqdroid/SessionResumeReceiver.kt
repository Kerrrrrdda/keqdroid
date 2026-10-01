package com.keqdroid.keqdroid

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build

/**
 * Возвращает туннель после перезагрузки телефона и после обновления приложения.
 *
 * Оба события убивают процесс, не дав сервису выключиться штатно, так что
 * [KeqdisVpnService.KEY_QS_SESSION_WANTED] остаётся таким, каким был при жизни.
 * Был VPN включён — поднимаем его по снапшоту, тем же путём, что и плитка.
 * Иначе после обновления из самого приложения VPN оказывался выключенным.
 */
class SessionResumeReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val note = when (intent.action) {
            Intent.ACTION_MY_PACKAGE_REPLACED ->
                "the app was updated while the VPN was on, reconnecting"
            Intent.ACTION_BOOT_COMPLETED ->
                "the phone restarted while the VPN was on, reconnecting"
            else -> return
        }
        val prefs = context.getSharedPreferences(KeqdisVpnService.PREFS_QS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(KeqdisVpnService.KEY_QS_SESSION_WANTED, false)) return

        val start = KeqdisVpnService.snapshotStartIntent(context)
        if (start == null) {
            NativeLog.w(TAG, "${intent.action}: the VPN was on, but there is no snapshot to reconnect with")
            return
        }
        // Согласие на VPN спрашивает только окно, а из фона его не открыть: раз
        // VPN с тех пор отдали другому приложению, вернуть его можно лишь вручную.
        if (KeqdisVpnService.startsTunnel(start) && VpnService.prepare(context) != null) {
            NativeLog.w(TAG, "${intent.action}: the VPN permission was taken away, staying down")
            return
        }
        start.putExtra(KeqdisVpnService.EXTRA_LOG_NOTE, note)
        try {
            // Старт из этих двух рассылок Android разрешает явно, отказать может
            // только прошивка — тогда остаётся как раньше, подключение вручную.
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(start) else context.startService(start)
            NativeLog.i(TAG, "${intent.action}: reconnecting to the last server")
        } catch (e: Exception) {
            NativeLog.e(TAG, "${intent.action}: service start refused by system: $e")
        }
    }

    private companion object {
        const val TAG = "KEQDIS_RESUME"
    }
}
