import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yamibo_flutter/data/theme_prefs.dart';
import 'package:yamibo_flutter/design/theme.dart';

/// 配色持久化回归（曾出现：切换主题没持久化，重启就失效）。
///
/// 测试环境没有 `ym/native` 通道，用临时文件顶替 `filesDir()`：
/// 验「切过的配色能读回来」与「通道缺失时静默降级回默认」。
///
/// 防抖是真实 Timer，别用固定 `Future.delayed` 去等它 —— 见 [waitFor]。
void main() {
  late Directory tempDir;
  late File saveFile;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('ym_theme_test');
    saveFile = File('${tempDir.path}${Platform.pathSeparator}ym_theme.json');
    YmThemePrefs.resetForTest(file: saveFile);
  });

  tearDown(() {
    YmThemePrefs.resetForTest();
    tempDir.deleteSync(recursive: true);
  });

  test('往返：切到轨交速查 落盘后能读回', () async {
    YmThemePrefs.instance.setThemeId(YmThemeId.rail);
    expect(YmThemePrefs.instance.themeId, YmThemeId.rail);
    await YmThemePrefs.saveNow();
    expect(saveFile.existsSync(), isTrue);

    // 模拟重启：内存态复位后从文件读回
    YmThemePrefs.resetForTest(file: saveFile);
    expect(YmThemePrefs.instance.themeId, YmThemeId.yamibo);
    await YmThemePrefs.load();

    expect(YmThemePrefs.instance.themeId, YmThemeId.rail);
  });

  test('切回默认也落盘（不是只在非默认时写）', () async {
    YmThemePrefs.instance.setThemeId(YmThemeId.rail);
    await YmThemePrefs.saveNow();
    YmThemePrefs.instance.setThemeId(YmThemeId.yamibo);
    await YmThemePrefs.saveNow();

    YmThemePrefs.resetForTest(file: saveFile);
    await YmThemePrefs.load();
    expect(YmThemePrefs.instance.themeId, YmThemeId.yamibo);
  });

  test('重复点同一胶囊不广播、不写盘', () async {
    var notified = 0;
    void listener() => notified++;
    YmThemePrefs.instance.addListener(listener);
    addTearDown(() => YmThemePrefs.instance.removeListener(listener));

    YmThemePrefs.instance.setThemeId(YmThemeId.yamibo); // 已经是默认值
    // 等过防抖窗口：没有变更就不该有排队的写盘任务，文件不该被建出来
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(notified, 0);
    expect(saveFile.existsSync(), isFalse);

    // 真切换：防抖到点后自动落盘，不需要手动 saveNow
    YmThemePrefs.instance.setThemeId(YmThemeId.rail);
    // ⚠ 别写死 `delayed(400ms)`：防抖是 300ms 的**真实** Timer，全量跑时机器一忙就会被推后，
    // 固定等待会偶发失败（2026-10-25 全量跑踩过两次，单跑必过）。等到条件成立为止。
    await waitFor(() => notified == 1 && saveFile.existsSync() && saveFile.lengthSync() > 0);
    // 落盘是异步 I/O：文件刚出现时可能还没写完，紧接着的 tearDown 删目录会撞上
    // 「文件被占用」（Windows 上 deleteSync 直接抛）。给它一点收尾时间。
    await Future<void>.delayed(const Duration(milliseconds: 120));
  });

  test('坏档 / 通道缺失静默降级为默认配色', () async {
    // 坏 JSON
    saveFile.writeAsStringSync('{not json');
    YmThemePrefs.resetForTest(file: saveFile);
    await YmThemePrefs.load();
    expect(YmThemePrefs.instance.themeId, YmThemeId.yamibo);

    // 通道缺失：_prefsFile 返回 null，读写都不抛
    YmThemePrefs.resetForTest(file: null);
    await YmThemePrefs.load();
    YmThemePrefs.instance.setThemeId(YmThemeId.rail);
    await YmThemePrefs.saveNow();
    expect(YmThemePrefs.instance.themeId, YmThemeId.rail);
  });
}

/// 轮询等到条件成立（最多 3 秒）。用于等**真实**防抖 Timer：写死等待时长在机器被占满时
/// 会偶发失败，而这个用例要断言的本来也不是「正好 400ms 内完成」，而是「最终会落盘」。
Future<void> waitFor(bool Function() cond, {Duration timeout = const Duration(seconds: 3)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
