import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// 应用版本号：取自**手机上安装的这个包**，不在代码里写死。
///
/// `pubspec.yaml` 不参与编译，运行时的 Dart 代码读不到它；而 `package_info_plus`
/// 拿到的是 Android 清单里由构建自动注入的 `versionName` / `versionCode`，
/// 天然等于打包那一刻 `pubspec.yaml` 的 `version`。所以以后升版本只改
/// `pubspec.yaml` 一处，界面自己跟上。
///
/// ⚠ 这是**宿主能力**（走平台通道），不属于设计令牌；放在 design 层只是因为它
/// 是跨页面的公共小件，且关于页从这一层取东西（与 `tokens.dart` 同级引用）。
///
/// 用法（不阻塞首帧，读到后自动刷新）：
/// ```dart
/// YmAppVersion.ensureLoaded();  // 幂等，重复调用只读一次
/// ValueListenableBuilder<String>(
///   valueListenable: YmAppVersion.label,
///   builder: (_, v, __) => v.isEmpty ? const SizedBox.shrink() : Text(v),
/// );
/// ```
class YmAppVersion {
  YmAppVersion._();

  /// 形如 `v0.1.4 (2005)`；`buildNumber` 为空时只有 `v0.1.4`。
  ///
  /// 读取失败或还没读到时是**空串** —— 不编一个默认版本号，
  /// 否则等于又写死一处。空串时页面整行不显示（不闪 `v0.0.0`）。
  static final ValueNotifier<String> label = ValueNotifier<String>('');

  /// 首次读取的 Future，用来保证"只读一次、不每帧读平台通道"。
  static Future<void>? _loading;

  /// 幂等：只在第一次真读，之后直接复用缓存结果。
  /// 永不抛异常（失败就留空串）。
  static Future<void> ensureLoaded() => _loading ??= _load();

  static Future<void> _load() async {
    try {
      final info = await PackageInfo.fromPlatform();
      label.value = _format(info.version, info.buildNumber);
    } catch (_) {
      // 拿不到就空着：宁可这行不显示，也不显示一个编出来的版本。
      label.value = '';
    }
  }

  static String _format(String version, String buildNumber) =>
      buildNumber.isEmpty ? 'v$version' : 'v$version ($buildNumber)';

  /// 仅供测试：清掉缓存，让下一次 `ensureLoaded()` 重新读（配合
  /// `PackageInfo.setMockInitialValues` 换一组假版本）。
  @visibleForTesting
  static void debugReset() {
    _loading = null;
    label.value = '';
  }
}
