import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../design/theme.dart';
import 'native_bridge.dart';

/// 配色方案偏好（对齐 uni 版 `ym_theme_v1` 的口径，独立文件存盘）。
///
/// 「我的」页切换后经 [setThemeId] 广播；`YamiboApp` 监听本单例重建 `MaterialApp`，
/// 于是重启后从 `ym_theme.json` 读回来的配色就是首屏配色。
/// 落盘走 300ms 防抖，与 `YmMangaPrefs` / `YmLibrary` 同一套节奏。
class YmThemePrefs extends ChangeNotifier {
  YmThemePrefs._();

  static final YmThemePrefs instance = YmThemePrefs._();

  static const String _fileName = 'ym_theme.json';

  /// 配色方案，默认百合会（与 uni 版 `data-theme` 缺省一致）。
  YmThemeId themeId = YmThemeId.yamibo;

  static bool _loaded = false;
  static File? _file;
  static Timer? _saveTimer;

  static Future<File?> _prefsFile() async {
    final cached = _file;
    if (cached != null) return cached;
    final dir = await YmNative.filesDir();
    if (dir == null || dir.isEmpty) return null;
    return _file = File('$dir${Platform.pathSeparator}$_fileName');
  }

  /// 读档（首启调用一次即可；读不到就保持默认值，**不抛错**）。
  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = await _prefsFile();
      if (file == null || !await file.exists()) return;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return;
      final json = jsonDecode(raw);
      if (json is! Map<String, Object?>) return;
      instance.themeId = switch (json['themeId']) {
        'rail' => YmThemeId.rail,
        _ => YmThemeId.yamibo,
      };
    } catch (_) {
      // 坏档当默认值，接下来的修改会覆盖
    }
  }

  /// 切配色：值没变就不重建、不写盘（重复点同一个胶囊是空操作）。
  void setThemeId(YmThemeId id) {
    if (themeId == id) return;
    themeId = id;
    notifyListeners();
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 300), _save);
  }

  static Future<void> _save() async {
    // 先掐掉排队中的防抖任务：手工落盘后不该再被旧计时器多写一遍
    _saveTimer?.cancel();
    _saveTimer = null;
    try {
      final file = await _prefsFile();
      if (file == null) return;
      final payload = <String, Object?>{
        'themeId': switch (instance.themeId) {
          YmThemeId.rail => 'rail',
          YmThemeId.yamibo => 'yamibo',
        },
      };
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(payload), flush: true);
    } catch (_) {
      // 写失败只影响「下次启动还记不记得」，不阻塞当前操作
    }
  }

  @visibleForTesting
  static void resetForTest({File? file}) {
    _saveTimer?.cancel();
    _saveTimer = null;
    _file = file;
    _loaded = false;
    instance.themeId = YmThemeId.yamibo;
  }

  @visibleForTesting
  static Future<void> saveNow() => _save();
}
