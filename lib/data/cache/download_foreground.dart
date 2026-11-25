import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 下载前台服务（第十九期 3，2026-11-24 用户要求「允许后台下载」）。
///
/// 为什么要有它：下载循环跑在应用进程里，Android 8 起进程一到后台就会被系统
/// 冻结 / 杀掉，表现为「切出去一会儿就停在那一页」。挂一条常驻通知（前台服务）
/// 才能让进程在**切到别的应用 / 熄屏**时继续跑。
///
/// 边界（别对外承诺过头）：
/// * **不保证**「从最近任务里划掉」之后还能活 —— 那会直接杀进程，重启后队列按
///   老口径回 paused，等用户再点；
/// * 不引第三方通知插件，自己走 `ym/download_foreground` 通道（原生只做展示，
///   下载逻辑仍在 Dart 队列里）；
/// * 测试 / 桌面 / 非 Android 一律静默跳过，不抛（widget 测试里没有这个通道）。
class YmDownloadForeground {
  YmDownloadForeground._();

  static const MethodChannel _channel = MethodChannel('ym/download_foreground');

  /// 通知是不是已经起来了（起来了再 `update` 才有意义，也避免重复申请权限）。
  static bool get running => _running;
  static bool _running = false;

  /// 当前应该显示在通知里的文案。队列每页都会调 [update]，这里节流 700ms：
  /// 漫画一话 38 页 ≈ 50 秒，逐页刷通知足够跟手，又不至于把通知栏刷爆。
  static String _text = '';
  static DateTime? _lastPushed;

  static bool get _supported =>
      !kIsWeb && Platform.isAndroid && !disabledForTest;

  /// 测试里显式关掉：widget 测试跑在主机 VM 上（`Platform.isAndroid` 本来就是
  /// false），这个开关再兜一层，免得有人把 channel 打到半截留下 pending 任务。
  static bool disabledForTest = false;

  /// 开跑第一个任务时调：起服务 + 第一条文案。
  static Future<void> start(String text) async {
    if (!_supported || text.isEmpty) return;
    final ok = await _invoke('start', text);
    _running = ok;
    _text = text;
    _lastPushed = DateTime.now();
  }

  /// 进度变了调：只改通知文案（服务已起就改，没起就不管）。
  static Future<void> update(String text) async {
    if (!_supported || !_running || text.isEmpty || text == _text) return;
    final last = _lastPushed;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(milliseconds: 700)) {
      return;
    }
    _text = text;
    _lastPushed = DateTime.now();
    await _invoke('update', text);
  }

  /// 队列跑空 / 被停时调：撤通知、停服务。
  static Future<void> stop() async {
    if (!_supported) return;
    if (!_running) return;
    _running = false;
    _text = '';
    _lastPushed = null;
    await _invoke('stop', '');
  }

  /// 仅供测试：清掉内存态（不影响真机服务）。
  @visibleForTesting
  static void resetForTest() {
    _running = false;
    _text = '';
    _lastPushed = null;
  }

  /// 通道调用失败一律当「没开成通知」：下载本身不能因为通知挂了而停下。
  static Future<bool> _invoke(String method, String text) async {
    try {
      final ok = await _channel.invokeMethod<bool>(method, {'text': text});
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
