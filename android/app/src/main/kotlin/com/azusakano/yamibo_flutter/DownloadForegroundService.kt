package com.azusakano.yamibo_flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * 下载前台服务：只为「退到后台 / 熄屏后还能接着下」。
 *
 * 为什么必须开前台服务：Android 8 起后台进程会被系统随时冻结 / 杀掉，Flutter 的
 * 下载循环跑在应用进程里，没有前台服务就会被掐断。挂一条常驻通知后，进程在
 * 「用户切到别的应用 / 锁屏」时仍可继续跑（仍不保证「从最近任务里划掉」之后能活，
 * 那会直接杀进程 —— 重启后队列按老口径回 paused，等用户再点）。
 *
 * 只做进度展示，不持有下载逻辑：真正的下载在 Dart 侧串行队列里，这里只是
 * `startForeground` + 改文案。文案由 Dart 通过 `ym/download_foreground` 通道推过来。
 */
class DownloadForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra(EXTRA_TEXT).orEmpty()
        if (text.isEmpty()) {
            stopSelf()
            return START_NOT_STICKY
        }
        startAsForeground(buildNotification(text))
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        super.onDestroy()
    }

    private fun startAsForeground(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    /** 点通知回到应用（不新建任务栈，已经在就切回来）。 */
    private fun buildNotification(text: String): Notification {
        val open = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pi = PendingIntent.getActivity(
            this,
            0,
            open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            // 抬头固定为「正在离线保存」（独立标题，末尾不带冒号），正文由 Dart 推
            // （作品 · 这一话 · 页数）。不再写「百合会」当抬头：用户 2026-11-24
            // 第二轮要求把抬头让给动作本身；无用冒号在第三期去掉。
            .setContentTitle("正在离线保存")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            // 常驻：用户不能左滑消掉（否则服务在前台却没有通知，系统会判违规）
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setContentIntent(pi)
            .build()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        // 低优先级：不出声、不弹横幅，只在通知栏里安静显示进度
        val channel = NotificationChannel(
            CHANNEL_ID,
            "离线下载",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "正在把小说 / 漫画存到本机"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    companion object {
        const val CHANNEL_ID = "ym_download"
        const val NOTIFICATION_ID = 1001
        const val EXTRA_TEXT = "text"

        /** 起 / 改文案都走这一个入口：带着新文案 startService，服务自己刷新通知。 */
        fun push(context: Context, text: String) {
            val intent = Intent(context, DownloadForegroundService::class.java)
                .putExtra(EXTRA_TEXT, text)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun cancel(context: Context) {
            context.stopService(Intent(context, DownloadForegroundService::class.java))
        }
    }
}
