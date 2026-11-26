import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yamibo_flutter/data/cache/ym_cache_store.dart';

/// 磁盘缓存地基：落盘、索引、淘汰与损坏容错。
/// 测试环境没有 `ym/native` 通道，用临时目录顶替 `filesDir()`。
Future<void> _cleanup(Directory dir) async {
  for (var i = 0; i < 6; i++) {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      return;
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
  }
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('ym_cache_test');
    YmCache.resetForTest(dir: tempDir);
  });

  tearDown(() async {
    YmCache.resetForTest();
    await _cleanup(tempDir);
  });

  group('原文读写', () {
    test('写后读回逐字相等；没写过的 key 返回 null', () async {
      const html = '<html><body><div id="chapterContent"><p>第一段</p></div></body></html>';
      await YmCache.instance.writeHtml('novel:38819549', html);
      expect(await YmCache.instance.readHtml('novel:38819549'), html);
      expect(await YmCache.instance.readHtml('novel:1'), isNull);
    });

    test('落盘路径由 key 推出来（小说 / 论坛一个 unit 一个文件，漫画按页）', () async {
      await YmCache.instance.writeHtml('novel:38819549', 'A');
      // 漫画按页落盘（`manga/<chaptId>/<page>.html`）：一话 38 页，
      // 原来 `manga/<chaptId>.html` 会让第 2 页盖掉第 1 页
      await YmCache.instance.writeHtml('manga:378:1', 'B');
      await YmCache.instance.writeHtml('forum:577729:2', 'C');

      final novel = File('${tempDir.path}/novel/38819549.html');
      final manga = File('${tempDir.path}/manga/378/1.html');
      final forum = File('${tempDir.path}/forum/577729/2.html');
      expect(novel.existsSync(), isTrue);
      expect(manga.existsSync(), isTrue);
      expect(forum.existsSync(), isTrue);
      expect(novel.readAsStringSync(), 'A');
      expect(forum.readAsStringSync(), 'C');
      // 不留 .tmp 半截文件
      expect(File('${novel.path}.tmp').existsSync(), isFalse);
    });

    test('写盘后不留 .tmp；索引文件也是原子写出来的', () async {
      await YmCache.instance.upsert(
        YmCacheEntry(
          key: 'novel:1',
          source: 'novel',
          parent: '267',
          title: '第1章',
          state: YmCacheState.queued,
        ),
      );
      expect(File('${tempDir.path}/index.json').existsSync(), isTrue);
      expect(File('${tempDir.path}/index.json.tmp').existsSync(), isFalse);
    });
  });

  group('索引', () {
    test('落盘后重开能读回（状态 / 字节 / 序号 / 总章数都在）', () async {
      await YmCache.instance.upsert(
        YmCacheEntry(
          key: 'novel:38819549',
          source: 'novel',
          parent: '267',
          parentTitle: '作品名',
          title: '第1章 一切的开始',
          total: 53,
          order: 1,
          state: YmCacheState.queued,
        ),
      );
      await YmCache.instance.writeHtml('novel:38819549', 'x' * 40);
      final bytes = await YmCache.instance.bytesOf('novel:38819549');
      await YmCache.instance.markDone('novel:38819549', bytes: bytes);
      expect((await YmCache.instance.entryOf('novel:38819549'))!.state, YmCacheState.done);

      // 模拟重启
      await YmCache.loadNow();

      final entry = await YmCache.instance.entryOf('novel:38819549');
      expect(entry, isNotNull);
      expect(entry!.state, YmCacheState.done);
      expect(entry.parent, '267');
      expect(entry.parentTitle, '作品名');
      expect(entry.title, '第1章 一切的开始');
      expect(entry.total, 53);
      expect(entry.order, 1);
      expect(entry.bytes, 40);
      expect(entry.at, greaterThan(0));
    });

    test('entriesOfParent 只返回这本作品的 unit，并按序号排', () async {
      for (final (id, order) in [('3', 3), ('1', 1), ('2', 2)]) {
        await YmCache.instance.upsert(
          YmCacheEntry(
            key: 'novel:$id',
            source: 'novel',
            parent: '267',
            title: '第$id章',
            order: order,
            state: YmCacheState.done,
            bytes: 1,
            at: 1,
          ),
        );
      }
      await YmCache.instance.upsert(
        YmCacheEntry(
          key: 'novel:9',
          source: 'novel',
          parent: '999',
          title: '别的作品',
          state: YmCacheState.done,
        ),
      );

      final list = await YmCache.instance.entriesOfParent('novel', '267');
      expect(list.length, 3);
      expect(list.map((e) => e.order), [1, 2, 3]);
      expect(list.every((e) => e.parent == '267'), isTrue);
    });

    test('坏 JSON：当空索引，不抛', () async {
      File('${tempDir.path}/index.json').writeAsStringSync('不是JSON{{{');
      await YmCache.loadNow();
      expect(YmCache.instance.peekAll(), isEmpty);
      expect(await YmCache.instance.totalBytes(), 0);
    });

    test('索引里 units 不是数组：同样当空', () async {
      File('${tempDir.path}/index.json').writeAsStringSync(jsonEncode({'units': 42}));
      await YmCache.loadNow();
      expect(YmCache.instance.peekAll(), isEmpty);
    });
  });

  group('删除', () {
    test('删 unit 后文件不存在、索引也没有这条', () async {
      await YmCache.instance.upsert(
        YmCacheEntry(
          key: 'novel:1',
          source: 'novel',
          parent: '267',
          state: YmCacheState.done,
          bytes: 3,
        ),
      );
      await YmCache.instance.writeHtml('novel:1', 'abc');
      await YmCache.instance.removeUnit('novel:1');

      expect(File('${tempDir.path}/novel/1.html').existsSync(), isFalse);
      expect(await YmCache.instance.entryOf('novel:1'), isNull);
      await YmCache.loadNow();
      expect(await YmCache.instance.entryOf('novel:1'), isNull);
    });

    test('removeParent 删掉一本作品的全部章节，别的作品不受影响', () async {
      for (final (parent, id) in [('267', '1'), ('267', '2'), ('999', '3')]) {
        await YmCache.instance.upsert(
          YmCacheEntry(
            key: 'novel:$id',
            source: 'novel',
            parent: parent,
            state: YmCacheState.done,
            bytes: 1,
          ),
        );
        await YmCache.instance.writeHtml('novel:$id', 'x');
      }
      await YmCache.instance.removeParent('novel', '267');

      expect(await YmCache.instance.entryOf('novel:1'), isNull);
      expect(await YmCache.instance.entryOf('novel:2'), isNull);
      expect(await YmCache.instance.entryOf('novel:3'), isNotNull);
      expect(File('${tempDir.path}/novel/3.html').existsSync(), isTrue);
    });
  });

  group('容量统计（不设上限）', () {
    Future<void> addUnit(String id, int at, int bytes, {int? fileBytes}) async {
      await YmCache.instance.upsert(
        YmCacheEntry(
          key: 'novel:$id',
          source: 'novel',
          parent: '267',
          state: YmCacheState.queued,
        ),
      );
      // 文件写小一点没有关系：`bytes` 是索引里记的数，容量统计只认索引
      await YmCache.instance.writeHtml('novel:$id', 'x' * (fileBytes ?? bytes));
      await YmCache.instance.markDone('novel:$id', bytes: bytes, at: at);
    }

    test('只统计 done：排队 / 失败的不占容量', () async {
      await YmCache.instance.upsert(
        YmCacheEntry(
          key: 'novel:a',
          source: 'novel',
          parent: '267',
          state: YmCacheState.done,
          bytes: 500,
        ),
      );
      await YmCache.instance.upsert(
        YmCacheEntry(
          key: 'novel:b',
          source: 'novel',
          parent: '267',
          state: YmCacheState.failed,
          bytes: 900,
        ),
      );
      expect(await YmCache.instance.totalBytes(), 500);
      expect(YmCache.instance.usedBytes, 500);
    });

    test('落账一个再大的一条，之前的 done 一条都不删（没有自动淘汰）', () async {
      await addUnit('1', 100, 6);
      await addUnit('2', 200, 6);
      await addUnit('3', 300, 6);
      // 远超早先 2GB 那个量级也没关系：这里用「大到不可能有上限」的字节数
      await addUnit('4', 400, 4 * 1024 * 1024 * 1024, fileBytes: 4);

      // 四条文件全在，索引全在，没有「最老的被删」
      for (final id in ['1', '2', '3', '4']) {
        expect(File('${tempDir.path}/novel/$id.html').existsSync(), isTrue);
        expect(await YmCache.instance.entryOf('novel:$id'), isNotNull);
      }
      expect(await YmCache.instance.totalBytes(), 18 + 4 * 1024 * 1024 * 1024);
    });

    test('索引里有 done 但文件没了：重启后仍自洽（读时当未命中，统计不崩）', () async {
      await addUnit('1', 100, 6);
      await addUnit('2', 200, 6);
      // 模拟「落盘后文件被别的清理工具删掉」：索引里还有一条 done，文件已经没了
      File('${tempDir.path}/novel/3.html').writeAsStringSync('y' * 6);
      await YmCache.instance.upsert(
        YmCacheEntry(
          key: 'novel:3',
          source: 'novel',
          parent: '267',
          state: YmCacheState.done,
          bytes: 6,
          at: 300,
        ),
      );
      File('${tempDir.path}/novel/3.html').deleteSync();

      await YmCache.loadNow();
      // 索引里还在（读的时候会当未命中回源，不会崩），容量统计不至于失控
      expect(await YmCache.instance.entryOf('novel:3'), isNotNull);
      expect(await YmCache.instance.readHtml('novel:3'), isNull);
      expect(await YmCache.instance.totalBytes(), 18);
    });
  });
}
