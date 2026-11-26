import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yamibo_flutter/data/api.dart';
import 'package:yamibo_flutter/data/cache/download_queue.dart';
import 'package:yamibo_flutter/data/cache/image_bytes.dart';
import 'package:yamibo_flutter/data/cache/ym_cache_store.dart';
import 'package:yamibo_flutter/data/http.dart';
import 'package:yamibo_flutter/data/models.dart';

/// 缓存流水线的回归：章节页写入、图片落盘、命中与淘汰。
///
/// 网络与图片两条通道一律用 `debugHandler` 接管，**永不联网**：真实链路
/// 不可控，也不该让这些用例跟着红。

/// 一话 N 页的章节页原文（只保留 parser 认的那几样标记）。
///
/// `imgPic` 是当页图地址，`data-page="0..N-1"` 让 `parseMangaChapter`
/// 数出 `totalPages = N`。
String _pageListHtml(int total, {String id = '900', String tag = 'a'}) =>
    '<html><body><h3>第1话 测试</h3>'
    '<img id="imgPic" src="https://img.example/$tag-p1.jpg?sign=s&amp;t=1">'
    '<script>addMark(123, $id, 2);</script>'
    '${[for (var i = 0; i < total; i++) '<a data-page="$i" href="#">$i</a>'].join()}'
    '</body></html>';

/// 某一页的原文：图地址带上页号（测试靠它判「哪一页失败」）。
String _pageHtml(String id, int page, {int total = 3, String tag = 'a'}) =>
    '<html><body><h3>第1话 测试</h3>'
    '<img id="imgPic" src="https://img.example/$tag-p$page.jpg?sign=s&amp;t=1">'
    '<script>addMark(123, $id, 2);</script>'
    '${[for (var i = 0; i < total; i++) '<a data-page="$i" href="#">$i</a>'].join()}'
    '</body></html>';

int _reqPage(String path) {
  final m = RegExp(r'&page=(\d+)').firstMatch(path);
  return m == null ? 1 : int.parse(m.group(1)!);
}

YmMangaDetail _manga(List<String> ids, {String id = '900'}) => YmMangaDetail(
  id: id,
  title: '测试漫画',
  cover: '',
  author: '作者',
  translator: '译者',
  cat: '原创',
  status: '连载中',
  license: '普通',
  region: '中文',
  version: '正常',
  form: '连载',
  publishedAt: '2024-01-01',
  updatedAt: '2024-02-01',
  hits: '1',
  favs: '2',
  score: '3',
  intro: '',
  chapters: <YmChapterRef>[
    for (final ch in ids) YmChapterRef(id: ch, title: '第$ch话', volume: ''),
  ],
);

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

/// 等某个条件成立（最多 [timeout]）。
Future<void> _waitUntil(bool Function() cond, {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('ym_manga_cache_test');
    YmCache.resetForTest(dir: tempDir);
    YmDownloadQueue.resetForTest();
    clearCache();
    YmHttp.debugHandler = null;
    YmHttp.debugOnSend = null;
    YmImageBytes.debugHandler = null;
  });

  tearDown(() async {
    YmHttp.debugHandler = null;
    YmHttp.debugOnSend = null;
    YmImageBytes.debugHandler = null;
    YmDownloadQueue.resetForTest();
    YmCache.resetForTest();
    clearCache();
    await _cleanup(tempDir);
  });

  group('2A 字节通道', () {
    test('stub 返回什么就拿到什么（逐字节相等）', () async {
      final payload = Uint8List.fromList(<int>[1, 2, 3]);
      YmImageBytes.debugHandler = (url) async => payload;

      final got = await YmImageBytes.fetch('https://img.example/a.jpg');
      expect(got.length, 3);
      expect(got, payload);
    });

    test('stub 抛错：原样向上抛 YmHttpError', () async {
      YmImageBytes.debugHandler = (url) async =>
          throw YmHttpError('站点返回 403', code: 'HTTP', status: 403);

      await expectLater(
        YmImageBytes.fetch('https://img.example/a.jpg'),
        throwsA(
          isA<YmHttpError>()
              .having((e) => e.code, 'code', 'HTTP')
              .having((e) => e.status, 'status', 403),
        ),
      );
    });

    test('超过单张上限判失败（不截断、不落内存）', () async {
      // 上限上面再给 1 个字节
      final tooBig = Uint8List(YmImageBytes.maxImageBytes + 1);
      YmImageBytes.debugHandler = (url) async => tooBig;

      await expectLater(
        YmImageBytes.fetch('https://img.example/huge.jpg'),
        throwsA(isA<YmHttpError>()),
      );
    });
  });

  group('2B 存储层', () {
    test('key → 路径：漫画按页落盘，小说 / 论坛口径不变', () {
      expect(YmCache.relativePathOf('manga:1:2'), 'manga/1/2.html');
      expect(YmCache.relativePathOf('manga:1:1'), 'manga/1/1.html');
      expect(YmCache.relativeImagePathOf('1', 2), 'manga/1/2.jpg');
      expect(YmCache.relativePathOf('novel:38819549'), 'novel/38819549.html');
      expect(YmCache.relativePathOf('forum:12:1'), 'forum/12/1.html');
      // 两段式漫画 key 是索引里的 unit，没有单文件
      expect(YmCache.relativePathOf('manga:1'), isNull);
    });

    test('p1 / p2 各写各的，互不覆盖', () async {
      await YmCache.instance.writeHtml('manga:1:1', '第一页');
      await YmCache.instance.writeHtml('manga:1:2', '第二页');

      expect(await YmCache.instance.readPageHtml('1', 1), '第一页');
      expect(await YmCache.instance.readPageHtml('1', 2), '第二页');
    });

    test('不安全字符被挡掉，不会把路径带歪', () {
      // `/` `:` 之外的字符一律换成 `_`，`.` 留着但也出不了 manga 这一层
      expect(YmCache.relativePathOf('manga:../1:2'), 'manga/.._1/2.html');
      expect(YmCache.relativePathOf('manga:1:../../x'), 'manga/1/.._.._x.html');
      expect(YmCache.relativePathOf('manga::1'), isNull);
    });

    test('writeImage 落盘长度与入参一致，peekImageFile 立刻能看到', () async {
      final bytes = List<int>.generate(64, (i) => i);
      await YmCache.instance.writeImage('900', 2, bytes);

      final file = YmCache.instance.peekImageFile('900', 2);
      expect(file, isNotNull);
      expect(file!.readAsBytesSync(), bytes);
      expect(file.lengthSync(), 64);
      // 相邻页没有文件
      expect(YmCache.instance.peekImageFile('900', 1), isNull);
    });

    test('目录没就绪时 peekImageFile 返回 null（不 await 原生通道）', () {
      YmCache.resetForTest(); // 既没有测试目录也没有原生通道
      expect(YmCache.instance.peekImageFile('900', 1), isNull);
    });

    test('删 unit 会连整话目录一起删掉', () async {
      await YmCache.instance.writeHtml('manga:900:1', '第一页');
      await YmCache.instance.writeImage('900', 1, <int>[1, 2, 3]);
      await YmCache.instance.upsert(
        YmCacheEntry(key: 'manga:900', source: 'manga', parent: '900'),
      );

      await YmCache.instance.removeUnit('manga:900');
      expect(YmCache.instance.peekImageFile('900', 1), isNull);
      expect(await YmCache.instance.readPageHtml('900', 1), isNull);
      expect(Directory('${tempDir.path}/manga/900').existsSync(), isFalse);
    });
  });

  group('2C 队列：漫画一话', () {
    test('排 1 话 2 页：2 份原文 + 2 张图落盘，done，bytes 是四者之和', () async {
      final hs = <String>[
        _pageHtml('900', 1, total: 2),
        _pageHtml('900', 2, total: 2),
      ];
      YmHttp.debugHandler = (path) async =>
          YmRawResponse(status: 200, body: hs[_reqPage(path) - 1]);
      final img = Uint8List.fromList(<int>[7, 8, 9]);
      final imgUrls = <String>[];
      YmImageBytes.debugHandler = (url) async {
        imgUrls.add(url);
        return img;
      };

      final detail = _manga(['900']);
      await YmDownloadQueue.instance.enqueueManga(detail, detail.chapters);
      await YmDownloadQueue.instance.drain();

      for (var page = 1; page <= 2; page++) {
        final file = File('${tempDir.path}/manga/900/$page.html');
        expect(file.existsSync(), isTrue, reason: '第 $page 页原文');
        expect(file.readAsStringSync(), hs[page - 1]);
        final image = File('${tempDir.path}/manga/900/$page.jpg');
        expect(image.existsSync(), isTrue, reason: '第 $page 页图');
        expect(image.readAsBytesSync(), img);
      }
      // 图地址用的是 parser 给的，一页一张
      expect(imgUrls.length, 2);
      expect(imgUrls[0], contains('p1.jpg'));
      expect(imgUrls[1], contains('p2.jpg'));

      final entry = await YmCache.instance.entryOf('manga:900');
      expect(entry!.state, YmCacheState.done);
      expect(entry.pages, 2);
      final expectBytes =
          utf8.encode(hs[0]).length +
          3 +
          utf8.encode(hs[1]).length +
          3;
      expect(entry.bytes, expectBytes);
      expect(await YmCache.instance.totalBytes(), expectBytes);
      expect(YmDownloadQueue.instance.busy, isFalse);
    });

    test('第 2 页图失败：整话 failed 且文案带页号，后面的话照跑', () async {
      YmHttp.debugHandler = (path) async {
        final id = path.contains('id=901') ? '901' : '900';
        return YmRawResponse(
          status: 200,
          // 两话用不同图名前缀，才能只让第一话的第 2 页失败
          body: _pageHtml(id, _reqPage(path), total: 3, tag: id == '900' ? 'a' : 'b'),
        );
      };
      YmImageBytes.debugHandler = (url) async {
        if (url.contains('a-p2')) {
          throw YmHttpError('站点返回 403', code: 'HTTP', status: 403);
        }
        return Uint8List.fromList(<int>[1, 1, 1]);
      };

      final detail = _manga(['900', '901']);
      await YmDownloadQueue.instance.enqueueManga(detail, detail.chapters);
      await YmDownloadQueue.instance.drain();

      final first = YmDownloadQueue.instance
          .tasksOf('manga', '900')
          .firstWhere((t) => t.chaptId == '900');
      expect(first.state, YmCacheState.failed);
      expect(first.error, contains('第 2 页'));
      expect((await YmCache.instance.entryOf('manga:900'))!.state,
          YmCacheState.failed);

      final second = YmDownloadQueue.instance
          .tasksOf('manga', '900')
          .firstWhere((t) => t.chaptId == '901');
      expect(second.state, YmCacheState.done);
      expect(second.pagesDone, 3);
    });

    test('cancelAll：当前页之后不再发请求，任务回 paused', () async {
      final paths = <String>[];
      YmHttp.debugOnSend = (req) => paths.add(req.path);
      YmHttp.debugHandler = (path) async {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        return YmRawResponse(status: 200, body: _pageListHtml(5));
      };
      YmImageBytes.debugHandler = (url) async =>
          Uint8List.fromList(<int>[1, 2, 3]);

      final detail = _manga(['900']);
      await YmDownloadQueue.instance.enqueueManga(detail, detail.chapters);
      await _waitUntil(() => paths.isNotEmpty);
      await YmDownloadQueue.instance.cancelAll();
      await YmDownloadQueue.instance.drain();

      final n = paths.length;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(paths.length, n, reason: '停止后不许再发请求');
      final task = YmDownloadQueue.instance.tasksOf('manga', '900').single;
      expect(task.state, YmCacheState.paused);
      expect((await YmCache.instance.entryOf('manga:900'))!.state,
          YmCacheState.paused);
      // 一话没跑完：不计容量、不算下载完成
      expect((await YmCache.instance.entryOf('manga:900'))!.bytes, 0);
    });

    test('每页都通知一次（界面要跟手，不能攒到整话结束）', () async {
      YmHttp.debugHandler = (path) async =>
          YmRawResponse(status: 200, body: _pageHtml('900', _reqPage(path)));
      YmImageBytes.debugHandler = (url) async =>
          Uint8List.fromList(<int>[4]);

      var notes = 0;
      void listener() => notes++;
      YmDownloadQueue.instance.addListener(listener);
      addTearDown(() => YmDownloadQueue.instance.removeListener(listener));

      final detail = _manga(['900']);
      await YmDownloadQueue.instance.enqueueManga(detail, detail.chapters);
      await YmDownloadQueue.instance.drain();
      // 3 页 → 至少 3 次页级通知，再加开始 / 结束
      expect(notes, greaterThanOrEqualTo(3));
    });

    test('已下载的话不会被重复排队', () async {
      YmHttp.debugHandler = (path) async =>
          YmRawResponse(status: 200, body: _pageHtml('900', _reqPage(path)));
      YmImageBytes.debugHandler = (url) async =>
          Uint8List.fromList(<int>[1]);

      final detail = _manga(['900']);
      await YmDownloadQueue.instance.enqueueManga(detail, detail.chapters);
      await YmDownloadQueue.instance.drain();

      var count = 0;
      YmHttp.debugOnSend = (_) => count++;
      await YmDownloadQueue.instance.enqueueManga(detail, detail.chapters);
      await YmDownloadQueue.instance.drain();
      expect(count, 0);
    });
  });

  group('2D 读取接磁盘', () {
    test('页原文在磁盘：零请求，且解析结果与直读一致', () async {
      var requests = 0;
      YmHttp.debugHandler = (path) async {
        requests++;
        return YmRawResponse(status: 200, body: _pageHtml('900', 1));
      };

      await YmCache.instance.writeHtml('manga:900:1', _pageHtml('900', 1));
      await YmCache.instance.upsert(
        YmCacheEntry(
          key: 'manga:900',
          source: 'manga',
          parent: '900',
          state: YmCacheState.done,
        ),
      );

      final page = await fetchMangaChapter('900', page: 1);
      expect(requests, 0);
      expect(page.image, contains('p1.jpg'));
      expect(page.totalPages, 3);

      // 内存也填上了：再读一次仍零请求
      await fetchMangaChapter('900', page: 1);
      expect(requests, 0);
    });

    test('force:true 跳过磁盘直接回源（签名失效要新地址）', () async {
      var requests = 0;
      YmHttp.debugHandler = (path) async {
        requests++;
        return YmRawResponse(
          status: 200,
          body: _pageHtml('900', 1).replaceAll('p1.jpg', 'fresh.jpg'),
        );
      };

      await YmCache.instance.writeHtml('manga:900:1', _pageHtml('900', 1));
      final page = await fetchMangaChapter('900', page: 1, force: true);
      expect(requests, 1);
      expect(page.image, contains('fresh.jpg'));
    });

    test('磁盘里的原文坏了（登录页 / 解析不出图）：静默回源', () async {
      var requests = 0;
      YmHttp.debugHandler = (path) async {
        requests++;
        return YmRawResponse(status: 200, body: _pageHtml('900', 1));
      };

      await YmCache.instance.writeHtml('manga:900:1', '<html>请先登录</html>');
      final page = await fetchMangaChapter('900', page: 1);
      expect(requests, 1);
      expect(page.image, isNotEmpty);
    });

    test('文件删掉后恢复走网络', () async {
      var requests = 0;
      YmHttp.debugHandler = (path) async {
        requests++;
        return YmRawResponse(status: 200, body: _pageHtml('900', 1));
      };

      await YmCache.instance.writeHtml('manga:900:1', _pageHtml('900', 1));
      await YmCache.instance.removeUnit('manga:900');
      clearCache();

      final page = await fetchMangaChapter('900', page: 1);
      expect(requests, 1);
      expect(page.image, isNotEmpty);
    });

    test('fetchMangaPageHtml 不重试，且挡掉登录页 / 没图的页', () async {
      var requests = 0;
      YmHttp.debugHandler = (path) async {
        requests++;
        throw YmHttpError('站点返回 503', code: 'HTTP', status: 503);
      };
      await expectLater(
        fetchMangaPageHtml('900', 1),
        throwsA(isA<YmHttpError>()),
      );
      expect(requests, 1);

      requests = 0;
      YmHttp.debugHandler = (path) async {
        requests++;
        return YmRawResponse(status: 200, body: '<html>请先登录</html>');
      };
      await expectLater(
        fetchMangaPageHtml('900', 2),
        throwsA(isA<YmHttpError>()),
      );
      expect(requests, 1);
    });
  });
}
