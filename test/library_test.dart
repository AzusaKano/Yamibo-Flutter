import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yamibo_flutter/data/library.dart';

/// 书库持久化回归（曾出现：重启后书架 / 历史丢失）。
///
/// 测试环境没有 `ym/native` 通道，用临时文件顶替 `filesDir()`：
/// 验「写进去的能读回来」与「通道缺失时静默降级不抛」。
void main() {
  late Directory tempDir;
  late File saveFile;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('ym_library_test');
    saveFile = File('${tempDir.path}${Platform.pathSeparator}ym_library.json');
    YmLibrary.resetForTest(file: saveFile);
  });

  tearDown(() {
    YmLibrary.resetForTest();
    tempDir.deleteSync(recursive: true);
  });

  test('往返：书架 + 历史 落盘后能原样读回', () async {
    YmLibrary.instance
      ..toggleShelf('n123', title: '少女革命', author: '作者甲', kind: 'novel')
      ..toggleShelf('m456', title: '百合漫画', author: '作者乙', kind: 'manga')
      ..recordRead(
        id: 'n123',
        title: '少女革命',
        author: '作者甲',
        cat: '百合',
        kind: 'novel',
        chapterTitle: '第 3 话',
        chapterId: 'c3',
        percent: 0.42,
        cover: 'http://x/c.jpg',
        page: 2,
        pages: 10,
      )
      ..recordRead(
        id: 'm456',
        title: '百合漫画',
        author: '作者乙',
        cat: '漫画',
        kind: 'manga',
        chapterTitle: '单行本',
        percent: 1.0,
      );
    await YmLibrary.saveNow();
    expect(saveFile.existsSync(), isTrue);

    // 模拟重启：内存态清空后从文件读回
    YmLibrary.resetForTest(file: saveFile);
    await YmLibrary.load();

    final lib = YmLibrary.instance;
    expect(lib.onShelf('n123'), isTrue);
    expect(lib.onShelf('m456'), isTrue);
    expect(lib.shelfEntries.firstWhere((e) => e.id == 'n123').title, '少女革命');
    expect(lib.shelfEntries.firstWhere((e) => e.id == 'm456').kind, 'manga');

    expect(lib.history.length, 2);
    // 历史按 lastReadAt 倒序：后读的 m456 在前
    expect(lib.history.first.id, 'm456');
    final restored = lib.historyOf('n123')!;
    expect(restored.chapterTitle, '第 3 话');
    expect(restored.chapterId, 'c3');
    expect(restored.percent, 0.42);
    expect(restored.page, 2);
    expect(restored.pages, 10);
    expect(restored.lastReadAt.millisecondsSinceEpoch, greaterThan(0));
  });

  test('删除与清空历史也落盘：读回后确实没了', () async {
    YmLibrary.instance
      ..recordRead(
        id: 'a',
        title: '甲',
        author: '',
        cat: '',
        kind: 'novel',
        chapterTitle: '1',
        percent: 0,
      )
      ..recordRead(
        id: 'b',
        title: '乙',
        author: '',
        cat: '',
        kind: 'novel',
        chapterTitle: '1',
        percent: 0,
      )
      ..removeHistory('a');
    await YmLibrary.saveNow();

    YmLibrary.resetForTest(file: saveFile);
    await YmLibrary.load();
    expect(YmLibrary.instance.historyOf('a'), isNull);
    expect(YmLibrary.instance.historyOf('b'), isNotNull);

    YmLibrary.instance.clearHistory();
    await YmLibrary.saveNow();
    YmLibrary.resetForTest(file: saveFile);
    await YmLibrary.load();
    expect(YmLibrary.instance.history, isEmpty);
  });

  test('通道缺失（无文件）：load / 落盘都静默降级，不抛错', () async {
    YmLibrary.resetForTest();
    await YmLibrary.load();
    YmLibrary.instance
      ..toggleShelf('x', title: '作品', author: '', kind: 'novel')
      ..recordRead(
        id: 'x',
        title: '作品',
        author: '',
        cat: '',
        kind: 'novel',
        chapterTitle: '1',
        percent: 0,
      );
    await YmLibrary.saveNow();
    expect(YmLibrary.instance.onShelf('x'), isTrue);
  });

  test('坏档：内容不是 JSON 时当空书架，不抛错', () async {
    saveFile.writeAsStringSync('不是JSON{{{');
    await YmLibrary.load();
    expect(YmLibrary.instance.shelfEntries, isEmpty);
    expect(YmLibrary.instance.history, isEmpty);
  });

  group('书架封面（曾出现：书架显示不出封面）', () {
    test('加入书架时带上封面，落盘后原样读回', () async {
      YmLibrary.instance.toggleShelf(
        '264784',
        title: '身为魔王的我以圣女的身份与勇者同行',
        author: 'Xmage',
        kind: 'novel',
        cover: 'https://www.yamibo.com/covern/000/264/784.jpg',
      );
      await YmLibrary.saveNow();

      YmLibrary.resetForTest(file: saveFile);
      await YmLibrary.load();
      final entry = YmLibrary.instance.shelfEntries.single;
      expect(entry.cover, 'https://www.yamibo.com/covern/000/264/784.jpg');
    });

    test('旧档没存封面：读回时用同 id 的阅读记录补上', () async {
      // 手写一份「升级前」的存档：书架条目只有 id/title/author/kind
      saveFile.writeAsStringSync(
        '{"shelf":[{"id":"171","title":"减法累述","author":"柾塚ちい","kind":"manga"}],'
        '"history":[{"id":"171","title":"减法累述","author":"柾塚ちい","cat":"原创",'
        '"kind":"manga","cover":"https://www.yamibo.com/coverm/000/000/171.jpg?=1601562184",'
        '"chapterId":"781","chapterTitle":"第1章","percent":1.0,"lastReadAt":1792833859520}]}',
      );
      await YmLibrary.load();

      final entry = YmLibrary.instance.shelfEntries.single;
      expect(entry.cover, 'https://www.yamibo.com/coverm/000/000/171.jpg?=1601562184');
      expect(
        YmLibrary.instance.coverOf(entry.id, entry.kind, cover: entry.cover),
        entry.cover,
      );
    });

    test('coverOf 兜底顺序：自带 → 历史 → 按 id 推图床地址', () {
      final lib = YmLibrary.instance;
      // 自带优先
      expect(
        lib.coverOf('171', 'manga', cover: 'http://a/b.jpg'),
        'http://a/b.jpg',
      );
      // 没有自带、也没有历史 ⇒ 按站点目录规则推（漫画 coverm / 小说 covern）
      expect(
        lib.coverOf('264784', 'novel'),
        'https://www.yamibo.com/covern/000/264/784.jpg',
      );
      expect(
        lib.coverOf('358', 'manga'),
        'https://www.yamibo.com/coverm/000/000/358.jpg',
      );
      // 非数字 id（测试夹具里的那种）推不出来，返回空串交给占位图
      expect(lib.coverOf('n123', 'novel'), '');
    });

    test('读一本已在书架但没封面的书：history 与 shelf 都补上封面', () {
      YmLibrary.instance
        ..toggleShelf('12345', title: '书', author: '甲', kind: 'novel')
        ..recordRead(
          id: '12345',
          title: '书',
          author: '甲',
          cat: '',
          kind: 'novel',
          chapterTitle: '第 1 章',
          percent: 0.1,
          cover: 'https://www.yamibo.com/covern/000/012/345.jpg?=1',
        );
      final entry = YmLibrary.instance.shelfEntries.single;
      expect(entry.cover, 'https://www.yamibo.com/covern/000/012/345.jpg?=1');
    });
  });
}
