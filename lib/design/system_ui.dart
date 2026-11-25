import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/services.dart';

const MethodChannel _systemUi = MethodChannel('ym/system_ui');

/// 阅读器的沉浸态：工具栏收起时同时隐藏系统状态栏和导航栏。
///
/// Android 必须走原生 `WindowInsetsController`：Flutter 的 `SystemUiMode.immersiveSticky`
/// 在引擎里仍是废弃的 `setSystemUiVisibility` flag，targetSdk 36（Android 16）会被系统忽略。
/// iOS 继续用 Flutter 的 `immersiveSticky`（隐藏状态栏和 home indicator）。
void setReaderImmersive(bool immersive) {
  if (defaultTargetPlatform == TargetPlatform.android) {
    _systemUi
        .invokeMethod<void>('setSystemBarsHidden', {'hidden': immersive})
        .catchError((Object _) {}); // 测试 / 无桥环境静默降级
    return;
  }
  SystemChrome.setEnabledSystemUIMode(
    immersive ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
  );
}
