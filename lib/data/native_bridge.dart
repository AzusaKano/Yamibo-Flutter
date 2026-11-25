import 'package:flutter/services.dart';

/// 原生桥（`MainActivity.kt` 的 `ym/native` 通道）。
///
/// 三个用途都在 Kotlin 侧注释里写明了：读 WebView Cookie、清 WebView Cookie、取私有目录。
/// 全部走 try/catch 降级：单元测试 / 桌面端没有这个通道，拿不到就当「没有」，不抛给页面。
class YmNative {
  YmNative._();

  static const MethodChannel _channel = MethodChannel('ym/native');

  /// 站点 Cookie 头（形如 `a=1; b=2`）；读不到返回空串。
  static Future<String> cookie(String url) async {
    try {
      final v = await _channel.invokeMethod<String>('getCookie', {'url': url});
      return v ?? '';
    } catch (_) {
      return '';
    }
  }

  /// 清 WebView Cookie 库；返回仍残留的 URL 数（0 = 清干净，-1 = 通道异常）。
  static Future<int> clearCookies(List<String> urls) async {
    try {
      final v = await _channel.invokeMethod<int>('clearCookies', {'urls': urls});
      return v ?? -1;
    } catch (_) {
      return -1;
    }
  }

  /// App 私有目录（`/data/user/0/<pkg>/files`）；取不到返回 null。
  static Future<String?> filesDir() async {
    try {
      return await _channel.invokeMethod<String>('filesDir');
    } catch (_) {
      return null;
    }
  }

  /// 拉起系统分享面板发一段文本（返回是否真的发出去了）。
  ///
  /// 通道不存在（测试 / 桌面端）时返回 false，由调用方降级成复制到剪贴板 ——
  /// 「分享」这个动作的底线是链接别丢，弹不弹系统面板是次要的。
  static Future<bool> shareText(String text, {String subject = ''}) async {
    if (text.isEmpty) return false;
    try {
      final v = await _channel.invokeMethod<bool>(
        'shareText',
        {'text': text, 'subject': subject},
      );
      return v ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 用系统浏览器打开一个 URL（`Intent.ACTION_VIEW`，Kotlin 侧实现）。
  ///
  /// 通道不存在（测试 / 桌面端）或拉不起来时返回 false，由调用方给人话提示。
  /// 外部浏览器没有登录态是预期结果，不在这里做 Cookie 注入。
  static Future<bool> openUrl(String url) async {
    if (url.isEmpty) return false;
    try {
      final v = await _channel.invokeMethod<bool>('openUrl', {'url': url});
      return v ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 调试用：往系统 Cookie 库写一条带属性的 cookie（App 主流程不调用）。
  static Future<bool> setCookie(String url, String value) async {
    try {
      final v = await _channel
          .invokeMethod<bool>('setCookie', {'url': url, 'value': value});
      return v ?? false;
    } catch (_) {
      return false;
    }
  }
}
