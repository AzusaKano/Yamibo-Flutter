import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yamibo_flutter/data/forum/forum_track.dart';

/// 论坛追帖 store 回归：落盘往返 / 坏档降级 / 容量淘汰 / tracked 与历史分流。
/// 测试环境没有 ym/native 通道，用临时文件顶替 filesDir()。
/// 只断言存储与状态，不碰任何观感数值。
void main() {
  late Directory tempDir;
  late File saveFile;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('ym_forum_track_test');
    saveFile = File('${tempDir.path}${Platform.pathSeparator}ym_forum_track.json');
    ForumTrackStore.resetForTest(file: saveFile);
  });

  tearDown(() {
    ForumTrackStore.resetForTest();
    tempDir.deleteSync(recursive: true);
  });

  test('往返：追帖 + 进度落盘后原样读回，记录按 lastReadAt 倒序', () async {
    final store = ForumTrackStore.instance;
    store.updateMeta(
        tid: '533721', title: '帖子甲', boardName: '小说区', author: '楼主甲', replies: 340);
    store.recordRead(
        tid: '533721', pid: '1234567', floor: 128, page: 7, totalPages: 12);
    store.track(tid: '533721');
    // 隔 2ms：让两条 lastReadAt 不同，倒序断言才确定（同一毫秒的顺序无意义）
    await Future<void>.delayed(const Duration(milliseconds: 2));
    store.updateMeta(tid: '900001', title: '帖子乙');
    store.recordRead(tid: '900001', pid: 'p1', floor: 3, page: 1);
    await ForumTrackStore.saveNow();
    expect(saveFile.existsSync(), isTrue);

    // 模拟重启：内存态清空后从文件读回
    ForumTrackStore.resetForTest(file: saveFile);
    await ForumTrackStore.load();

    final restored = ForumTrackStore.instance;
    expect(restored.recordCount, 2);
    expect(restored.trackedCount, 1);
    expect(restored.isTracked('533721'), isTrue);
    expect(restored.isTracked('900001'), isFalse);

    final a = restored.recordOf('533721')!;
    expect(a.title, '帖子甲');
    expect(a.boardName, '小说区');
    expect(a.author, '楼主甲');
    expect(a.replies, 340);
    expect(a.lastPid, '1234567');
    expect(a.lastFloor, 128);
    expect(a.lastPage, 7);
    expect(a.totalPages, 12);
    expect(a.tracked, isTrue);
    expect(a.lastReadAt, greaterThan(0));
    expect(a.savedAt, greaterThan(0));

    // 最近读的在前：900001 后读，排在 533721 前面
    expect(restored.records.first.tid, '900001');
    expect(restored.records.last.tid, '533721');
    expect(restored.trackedRecords.single.tid, '533721');
  });

  test('移出追帖只清 tracked：记录留在历史，进度不丢', () async {
    final store = ForumTrackStore.instance;
    store.track(tid: 't1', title: '标题');
    store.recordRead(tid: 't1', pid: 'p9', floor: 50, page: 3, totalPages: 8);
    store.untrack('t1');
    await ForumTrackStore.saveNow();

    ForumTrackStore.resetForTest(file: saveFile);
    await ForumTrackStore.load();
    final rec = ForumTrackStore.instance.recordOf('t1')!;
    expect(rec.tracked, isFalse);
    expect(rec.lastFloor, 50);
    expect(rec.lastPage, 3);
    expect(ForumTrackStore.instance.trackedCount, 0);
    expect(ForumTrackStore.instance.recordCount, 1);
  });

  test('清空历史只删未追帖记录：追帖及其进度保留', () async {
    final store = ForumTrackStore.instance;
    store.track(tid: 'keep', title: '追帖');
    store.recordRead(tid: 'keep', pid: 'pk', floor: 20, page: 2, totalPages: 5);
    store.recordRead(tid: 'drop', pid: 'pd', floor: 4, page: 1);
    store.clearHistory();
    await ForumTrackStore.saveNow();

    ForumTrackStore.resetForTest(file: saveFile);
    await ForumTrackStore.load();
    final restored = ForumTrackStore.instance;
    expect(restored.recordCount, 1);
    expect(restored.recordOf('drop'), isNull);
    expect(restored.recordOf('keep')!.lastFloor, 20);
    expect(restored.trackedCount, 1);
  });

  test('元数据回写不覆盖恢复进度（恢复入口首载不能被页顶抹掉）', () async {
    final store = ForumTrackStore.instance;
    // 已存进度：第 7 页 128 楼
    store.recordRead(
        tid: 'r1', pid: 'saved', floor: 128, page: 7, totalPages: 12);
    store.track(tid: 'r1');
    // 首载回写元数据（交接：author/replies/title/boardName 写回）
    store.updateMeta(
        tid: 'r1', title: '标题', boardName: '板块', author: '楼主', replies: 9);
    final rec = store.recordOf('r1')!;
    expect(rec.lastPid, 'saved');
    expect(rec.lastFloor, 128);
    expect(rec.lastPage, 7);
    expect(rec.title, '标题');
    expect(rec.author, '楼主');
  });

  test('totalPages=0 不抹掉已存的总页数（单页帖不能把页数写没）', () async {
    final store = ForumTrackStore.instance;
    store.recordRead(tid: 's1', pid: 'p1', floor: 2, page: 1, totalPages: 9);
    store.recordRead(tid: 's1', pid: 'p2', floor: 3, page: 1, totalPages: 0);
    expect(store.recordOf('s1')!.totalPages, 9);
  });

  test('容量：未追帖超过 200 条按 lastReadAt 淘汰最旧，追帖不参与', () async {
    final store = ForumTrackStore.instance;
    // 1 条追帖（最早读的），把未追帖撑到上限+若干
    store.recordRead(tid: 'tracked', pid: 'p', floor: 1, page: 1);
    store.track(tid: 'tracked');
    for (var i = 0; i < ForumTrackStore.maxUntracked + 5; i++) {
      // 逐条递增 lastReadAt：淘汰的必须是最旧的 h0..h4，剩 h5 起。
      store.recordRead(
          tid: 'h$i', pid: 'p', floor: 1, page: 1, immediate: i == 0);
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(store.recordCount, ForumTrackStore.maxUntracked + 1);
    expect(store.isTracked('tracked'), isTrue);
    // 最旧的 5 条未追帖被淘汰；h5（第 6 条）还在。
    expect(store.recordOf('h0'), isNull);
    expect(store.recordOf('h4'), isNull);
    expect(store.recordOf('h5'), isNotNull);
  });

  test('容量：移出追帖后当场淘汰（200 未追帖 + 1 追帖 → 200）', () async {
    final store = ForumTrackStore.instance;
    // 先把未追帖撑到上限：h0 最旧，h199 最新。
    for (var i = 0; i < ForumTrackStore.maxUntracked; i++) {
      store.recordRead(tid: 'h$i', pid: 'p', floor: 1, page: 1);
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    // 追帖在这之后才建（lastReadAt 最新），且不占未追帖额度。
    store.track(tid: 'tracked', title: '追帖');
    expect(store.recordCount, ForumTrackStore.maxUntracked + 1);

    // 移出追帖 ⇒ 这条也变成未追帖，总数越界 1 条，必须当场按 lastReadAt 淘汰最旧。
    store.untrack('tracked');
    expect(store.recordCount, ForumTrackStore.maxUntracked);
    expect(store.recordOf('h0'), isNull, reason: '最旧的未追帖被淘汰');
    expect(store.recordOf('h1'), isNotNull);
    expect(store.recordOf('tracked'), isNotNull, reason: '刚移出的这条留在历史');
    expect(store.isTracked('tracked'), isFalse);
  });

  test('坏档 / 通道缺失：当空记录，不抛错', () async {
    saveFile.writeAsStringSync('不是JSON{{{');
    await ForumTrackStore.load();
    expect(ForumTrackStore.instance.records, isEmpty);

    ForumTrackStore.resetForTest(); // 无文件 = 通道缺失
    await ForumTrackStore.load();
    ForumTrackStore.instance.track(tid: 'x', title: '作品');
    await ForumTrackStore.saveNow();
    expect(ForumTrackStore.instance.isTracked('x'), isTrue);
  });
}
