package com.azusakano.yamibo_flutter

import android.content.Intent
import android.os.Build
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.webkit.CookieManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 唯一的原生桥。只做三件事，全部围绕「系统 WebView 的 Cookie 库」：
 *
 * - `getCookie`：`webview_flutter` 只暴露 setCookie / removeAllCookies，**没有读回**的口子
 *   （Android 原生 getCookie 是回调式，pigeon 没包），而站内会话 `PHPSESSID` 是 HttpOnly，
 *   用 `document.cookie` 也拿不到。所以必须自己走 CookieManager。
 * - `clearCookies`：退出登录要连 WebView 的 Cookie 库一起清，否则下次打开登录页会被判定
 *   「已登录」，换不了账号（uni 版 2026-10-23 实测）。
 * - `filesDir`：`path_provider` / `shared_preferences` 新版都依赖 jni（要真 NDK + CMake），
 *   本机 NDK 是元数据桩 ⇒ Cookie 落盘自己取目录，用 dart:io 写。
 * - `shareText`：拉起系统分享面板（不引第三方插件，一个 Intent 就够）。
 * - `openUrl`：用系统浏览器打开链接（帖子页「在浏览器打开」）。
 * - `ym/system_ui` 的 `setSystemBarsHidden`：阅读器沉浸全屏（API 36 上 Flutter 的
 *   `SystemUiMode` 走废弃 flag，会被系统忽略，必须用 WindowInsetsController）。
 *
 * `setCookie` 只服务于 `lib/dev/verify_login_probe.dart`（验证 HttpOnly 能否读回）。
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getCookie" -> {
                        val url = call.argument<String>("url").orEmpty()
                        result.success(readCookie(url))
                    }
                    "setCookie" -> {
                        val url = call.argument<String>("url").orEmpty()
                        val value = call.argument<String>("value").orEmpty()
                        val cm = CookieManager.getInstance()
                        cm.setCookie(url, value)
                        cm.flush()
                        result.success(true)
                    }
                    "clearCookies" -> {
                        val urls = call.argument<List<String>>("urls").orEmpty()
                        result.success(clearCookies(urls))
                    }
                    "filesDir" -> result.success(filesDir.absolutePath)
                    // 拉起系统分享面板。用系统 Intent 而不是引第三方插件：
                    // 只需要「把一段文本发出去」，一个通道方法就够，省一层依赖与版本冲突。
                    "shareText" -> {
                        val text = call.argument<String>("text").orEmpty()
                        val subject = call.argument<String>("subject").orEmpty()
                        if (text.isEmpty()) {
                            result.success(false)
                        } else {
                            val send = Intent(Intent.ACTION_SEND).apply {
                                type = "text/plain"
                                putExtra(Intent.EXTRA_TEXT, text)
                                if (subject.isNotEmpty()) putExtra(Intent.EXTRA_SUBJECT, subject)
                            }
                            startActivity(Intent.createChooser(send, null))
                            result.success(true)
                        }
                    }
                    // 用系统浏览器打开 URL。外部浏览器没有本站登录态是预期结果。
                    "openUrl" -> {
                        val url = call.argument<String>("url").orEmpty()
                        if (url.isEmpty()) {
                            result.success(false)
                        } else {
                            result.success(openUrl(url))
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // 阅读器沉浸态。Flutter 的 SystemUiMode 在 targetSdk 36 / Android 16 上
        // 走的是已废弃的 setSystemUiVisibility，会被系统忽略，所以这里直接操作
        // WindowInsetsController（API 30+）。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SYSTEM_UI_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setSystemBarsHidden" -> {
                        val hidden = call.argument<Boolean>("hidden") ?: false
                        setSystemBarsHidden(hidden)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        // 下载前台服务（第十九期）：只为「退到后台 / 熄屏还接着下」。
        // Dart 侧只管推文案：start / update 都等价于「带上新文案起服务」，
        // stop = 停服务（通知随之消失）。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DOWNLOAD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start", "update" -> {
                        val text = call.argument<String>("text").orEmpty()
                        if (text.isEmpty()) {
                            DownloadForegroundService.cancel(this)
                            result.success(false)
                        } else {
                            result.success(pushDownload(text))
                        }
                    }
                    "stop" -> {
                        DownloadForegroundService.cancel(this)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 起前台服务。两件事要在这里兜住：
     * * Android 13 起通知要用户授权（拒绝也不影响下载，只是看不到进度条），
     *   第一次进来顺手申请一次，不阻塞调用；
     * * Android 12 起「从后台起前台服务」会被系统拒。用户点下载时应用在前台，
     *   正常不会命中；万一命中就返回 false，Dart 侧当「没开成通知」继续下。
     */
    private fun pushDownload(text: String): Boolean {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
                android.content.pm.PackageManager.PERMISSION_GRANTED
            ) {
                requestPermissions(
                    arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                    NOTIFICATION_REQUEST,
                )
            }
        } catch (e: Throwable) {
            // 申请失败不影响下载
        }
        return try {
            DownloadForegroundService.push(this, text)
            true
        } catch (e: Throwable) {
            false
        }
    }

    private fun setSystemBarsHidden(hidden: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val controller = window.insetsController ?: return
            if (hidden) {
                controller.systemBarsBehavior =
                    WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                controller.hide(WindowInsets.Type.systemBars())
            } else {
                controller.show(WindowInsets.Type.systemBars())
            }
            return
        }
        @Suppress("DEPRECATION")
        window.decorView.systemUiVisibility = if (hidden) {
            View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
                View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_FULLSCREEN or
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
        } else {
            0
        }
    }

    /** 拉起系统浏览器。无应用可处理 / 被系统拒绝时返回 false，调用方给人话提示。 */
    private fun openUrl(url: String): Boolean {
        return try {
            val intent = Intent(Intent.ACTION_VIEW, android.net.Uri.parse(url)).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            true
        } catch (e: Throwable) {
            false
        }
    }

    private fun readCookie(url: String): String {
        return try {
            val cm = CookieManager.getInstance()
            cm.flush()
            cm.getCookie(url) ?: ""
        } catch (e: Throwable) {
            ""
        }
    }

    /**
     * 逐个 cookie 写 Max-Age=0，仍残留就整体 removeAllCookies，最后 flush() 落盘。
     * 本客户端只访问 yamibo.com 域，整体清空不会误伤。
     * 返回清完后仍然读得到的 URL 数（0 = 清干净）。
     */
    private fun clearCookies(urls: List<String>): Int {
        return try {
            val cm = CookieManager.getInstance()
            for (url in urls) {
                val raw = try {
                    cm.getCookie(url)
                } catch (e: Throwable) {
                    null
                }
                if (raw.isNullOrEmpty()) continue
                for (pair in raw.split(";")) {
                    val name = pair.split("=")[0].trim()
                    if (name.isEmpty()) continue
                    try {
                        cm.setCookie(url, "$name=; Max-Age=0; Path=/")
                        cm.setCookie(url, "$name=; Max-Age=0; Path=/; Domain=.yamibo.com")
                    } catch (e: Throwable) {
                        // 单个 cookie 清不掉不影响其余
                    }
                }
            }
            var left = 0
            for (url in urls) {
                val raw = try {
                    cm.getCookie(url)
                } catch (e: Throwable) {
                    null
                }
                if (!raw.isNullOrEmpty()) left += 1
            }
            if (left > 0) {
                try {
                    cm.removeAllCookies(null)
                } catch (e: Throwable) {
                }
                left = 0
            }
            cm.flush()
            left
        } catch (e: Throwable) {
            -1
        }
    }

    companion object {
        const val CHANNEL = "ym/native"
        const val SYSTEM_UI_CHANNEL = "ym/system_ui"
        const val DOWNLOAD_CHANNEL = "ym/download_foreground"
        const val NOTIFICATION_REQUEST = 1001
    }
}
