import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yamibo_flutter/data/cache/ym_cache_store.dart';
import 'package:yamibo_flutter/data/library.dart';
import 'package:yamibo_flutter/design/theme.dart';
import 'package:yamibo_flutter/design/widgets/cover.dart';
import 'package:yamibo_flutter/design/widgets/lists.dart';
import 'package:yamibo_flutter/pages/shelf_page.dart';

/// 书架 / 历史 / 收藏的封面接本机那份。
///
/// 判据：断网（封面 URL 拉不动）时，**已下载过**的书要出本机封面；
/// 没下载过的仍是占位 —— 不造假。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('ym_shelf_cover_test');
    YmCache.resetForTest(dir: tempDir);
    await YmCache.load();
    YmLibrary.resetForTest(
      file: File('${tempDir.path}${Platform.pathSeparator}ym_library.json'),
    );
  });

  tearDown(() async {
    YmCache.resetForTest();
    YmLibrary.resetForTest();
    for (var i = 0; i < 6; i++) {
      try {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        break;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    }
  });

  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    final colors = ymPalette(YmThemeId.yamibo, Brightness.light);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildYmTheme(colors, Brightness.light),
        builder: (context, child) => YmScope(
          colors: colors,
          themeId: YmThemeId.yamibo,
          onThemeChanged: (_) {},
          child: child ?? const SizedBox.shrink(),
        ),
        home: page,
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 传进去的那张本机封面有没有被 YmCover 收下。
  File? localOf(WidgetTester tester, String title) {
    for (final c in tester.widgetList<YmCover>(find.byType(YmCover))) {
      if (c.title == title) return c.local;
    }
    return null;
  }

  testWidgets('书架：离线保存过的书用本机封面，没存过的不编一张图', (tester) async {
    await tester.runAsync(() async {
      await YmCache.instance.writeCover('novel', '267', <int>[1, 2, 3, 4]);
      YmLibrary.instance
        ..toggleShelf('267', title: '存过的书', author: '作者甲', kind: 'novel')
        ..toggleShelf('999', title: '没存过的书', author: '作者乙', kind: 'novel');
    });

    await pumpPage(tester, const ShelfPage());

    final stored = localOf(tester, '存过的书');
    expect(stored, isNotNull, reason: '已下载的作品要接本机封面');
    expect(stored!.path, contains('covers'));
    expect(localOf(tester, '没存过的书'), isNull,
        reason: '没下载过的书没有本机封面，保持占位（不造假）');
  });

  testWidgets('YmBookRow：传了本机文件时 YmCover.local 非空（封面链路透传）',
      (tester) async {
    final file = File('${tempDir.path}${Platform.pathSeparator}local.jpg')
      ..createSync(recursive: true);
    await pumpPage(
      tester,
      Scaffold(
        body: YmCardList(
          children: <Widget>[
            YmBookRow(title: '带本机封面', coverLocal: file, footTag: '小说'),
            const YmBookRow(title: '只有地址', cover: 'https://x/a.jpg'),
          ],
        ),
      ),
    );

    expect(localOf(tester, '带本机封面'), file);
    expect(localOf(tester, '只有地址'), isNull);
  });
}
