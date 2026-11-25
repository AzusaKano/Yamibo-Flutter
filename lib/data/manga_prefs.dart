import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'native_bridge.dart';

/// 漫画阅读偏好（对齐 uni 版 `ym_manga_prefs_v1` 的口径，独立文件存盘）。
///
/// 阅读器与设置面板都只读写这一个单例；改动经 [notifyListeners] 广播，
/// 落盘走 300ms 防抖（与 `YmLibrary` 同一套节奏）。
enum YmMangaMode { auto, flow, paged }

enum YmMangaDir { ltr, rtl }

class YmMangaPrefs extends ChangeNotifier {
  YmMangaPrefs._();

  static final YmMangaPrefs instance = YmMangaPrefs._();

  static const String _fileName = 'ym_manga_prefs.json';

  YmMangaMode mode = YmMangaMode.auto;
  YmMangaDir dir = YmMangaDir.ltr;

  /// 单页模式的图片适配：true = 适应宽度（铺宽），false = 整页 contain。
  bool fitWidth = false;

  /// 遮罩强度 0～0.6（叠一层可调透明黑，不动全局主题）。
  /// 旧档字段名是 `brightness`，读档时兼容。
  double maskOpacity = 0;

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
      final p = instance;
      p.mode = switch (json['mode']) {
        'flow' => YmMangaMode.flow,
        'paged' => YmMangaMode.paged,
        _ => YmMangaMode.auto,
      };
      p.dir = json['dir'] == 'rtl' ? YmMangaDir.rtl : YmMangaDir.ltr;
      p.fitWidth = json['fitWidth'] == true;
      p.maskOpacity =
          (json['maskOpacity'] as num?)?.toDouble() ?? (json['brightness'] as num?)?.toDouble() ?? 0;
      if (p.maskOpacity < 0) p.maskOpacity = 0;
      if (p.maskOpacity > 0.6) p.maskOpacity = 0.6;
    } catch (_) {
      // 坏档当默认值，接下来的修改会覆盖
    }
  }

  /// 变更后调用：防抖合并写盘（滑杆拖动会高频触发）。
  void changed() {
    notifyListeners();
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 300), _save);
  }

  static Future<void> _save() async {
    _saveTimer = null;
    try {
      final file = await _prefsFile();
      if (file == null) return;
      final p = instance;
      final payload = <String, Object?>{
        'mode': switch (p.mode) {
          YmMangaMode.flow => 'flow',
          YmMangaMode.paged => 'paged',
          YmMangaMode.auto => 'auto',
        },
        'dir': p.dir == YmMangaDir.rtl ? 'rtl' : 'ltr',
        'fitWidth': p.fitWidth,
        'maskOpacity': p.maskOpacity,
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
  }

  @visibleForTesting
  static Future<void> saveNow() => _save();
}
