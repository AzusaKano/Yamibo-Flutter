import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'native_bridge.dart';

/// 文字阅读偏好（字号 / 行距 / 简繁 / 翻页模式）。
///
/// 原先住在 `library.dart` 且只在内存里活（0.1.36~0.1.37 两期都是这样）；
/// 第十五期起独立成文件落盘：改一次字号重启就丢，和「阅读器」的定位不符。
/// 两个文字阅读器（论坛作品帖 / 站内小说）与设置面板共用**同一份实例**——
/// 一个阅读偏好，不分侧。落盘走 300ms 防抖，与 `YmThemePrefs` / `YmMangaPrefs`
/// 同一套节奏。
class YmReaderPrefs extends ChangeNotifier {
  YmReaderPrefs._();

  static final YmReaderPrefs instance = YmReaderPrefs._();

  static const String _fileName = 'ym_reader_prefs.json';

  /// 面板上的字号 / 行距可选档（档位值即渲染值，不做换算）。
  static const fonts = <double>[14, 17, 19, 22];
  static const lines = <double>[1.7, 1.9, 2.1];

  /// 正文基准字号（px）。
  double fontSize = 17;

  /// 正文行距（倍）。
  double lineHeight = 1.9;

  /// 简繁转换（小说侧用；论坛正文不转，见设置面板的字形注释）。
  bool traditional = false;

  /// 翻页模式：false = 上下滚动（默认，历史行为），true = 左右翻页（按屏分页）。
  bool paged = false;

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
      instance.fontSize =
          (json['fontSize'] as num?)?.toDouble() ?? instance.fontSize;
      instance.lineHeight =
          (json['lineHeight'] as num?)?.toDouble() ?? instance.lineHeight;
      instance.traditional =
          json['traditional'] as bool? ?? instance.traditional;
      instance.paged = json['paged'] as bool? ?? instance.paged;
    } catch (_) {
      // 坏档当默认值，接下来的修改会覆盖
    }
  }

  void setFontSize(double v) {
    if (fontSize == v) return;
    fontSize = v;
    _changed();
  }

  void setLineHeight(double v) {
    if (lineHeight == v) return;
    lineHeight = v;
    _changed();
  }

  void setTraditional(bool v) {
    if (traditional == v) return;
    traditional = v;
    _changed();
  }

  /// 切翻页模式：false = 上下滚动，true = 左右翻页。
  void setPaged(bool v) {
    if (paged == v) return;
    paged = v;
    _changed();
  }

  void _changed() {
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
        'fontSize': instance.fontSize,
        'lineHeight': instance.lineHeight,
        'traditional': instance.traditional,
        'paged': instance.paged,
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
    instance.fontSize = 17;
    instance.lineHeight = 1.9;
    instance.traditional = false;
    instance.paged = false;
  }

  @visibleForTesting
  static Future<void> saveNow() => _save();
}

/// 全局阅读偏好实例（历史出口，三个消费方经它订阅）。
final YmReaderPrefs readerPrefs = YmReaderPrefs.instance;
