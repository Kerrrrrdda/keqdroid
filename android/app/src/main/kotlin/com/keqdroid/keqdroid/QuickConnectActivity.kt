package com.keqdroid.keqdroid

import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts

/**
 * Невидимое окно, через которое плитка включает VPN, когда из шторки напрямую
 * не дают.
 *
 * Прошивки с «Автозапуском» (ColorOS/realme, MIUI и родня) молча отнимают у
 * плитки право поднять сервис, но окно из неё открыть дают, а из окна на
 * переднем плане сервис стартует всегда. Раньше в этом месте открывалось всё
 * приложение, и подключаться приходилось руками. Заодно окно спрашивает
 * согласие на VPN. Образец — TunnelToggleActivity в WireGuard.
 */
class QuickConnectActivity : ComponentActivity() {

    companion object {
        /// Когда окно открылось в последний раз (elapsedRealtime). По нему
        /// плитка узнаёт, что запуск из шторки не прошёл, — сам запуск об этом
        /// молчит.
        @JvmStatic
        @Volatile
        var openedAt: Long = 0L
            private set

        private const val STATE_ASKING_CONSENT = "asking_consent"
    }

    private var pending: Intent? = null
    private var askingConsent = false

    private val consent =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            askingConsent = false
            // Отказ в согласии — ответ, а не сбой: закрываемся молча.
            if (result.resultCode != RESULT_OK) {
                pending = null
                finish()
            }
            // Иначе стартует onResume, он придёт следом.
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        openedAt = SystemClock.elapsedRealtime()

        val start = KeqdisVpnService.snapshotStartIntent(this)
        if (start == null) {
            // Снапшот пропал между нажатием и окном — подключит приложение.
            openApp()
            finish()
            return
        }
        pending = start

        // Пересоздание посреди системного диалога: ответ на него ещё придёт,
        // второй диалог поверх первого не нужен.
        askingConsent = savedInstanceState?.getBoolean(STATE_ASKING_CONSENT) ?: false
        if (!askingConsent && KeqdisVpnService.startsTunnel(start)) {
            VpnService.prepare(this)?.let {
                askingConsent = true
                consent.launch(it)
            }
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean(STATE_ASKING_CONSENT, askingConsent)
    }

    // Старт в onResume, а не в onCreate: право на него даёт окно на переднем
    // плане, а на переднем плане оно только с этого момента.
    override fun onResume() {
        super.onResume()
        if (askingConsent) return
        val start = pending ?: return
        pending = null
        try {
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(start) else startService(start)
        } catch (e: Exception) {
            android.util.Log.e("KEQDIS_QS", "quick connect: service start refused: $e")
            runCatching { Toast.makeText(this, R.string.tile_error_start, Toast.LENGTH_LONG).show() }
            openApp()
        }
        finish()
    }

    private fun openApp() {
        runCatching {
            startActivity(
                Intent(this, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    .putExtra(MainActivity.EXTRA_LAUNCH_ACTION, MainActivity.LAUNCH_ACTION_CONNECT),
            )
        }
    }
}
