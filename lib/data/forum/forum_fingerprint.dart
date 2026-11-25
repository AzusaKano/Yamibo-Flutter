import 'dart:convert';

import 'forum_models.dart';

/// 帖子一页的**内容指纹**（2026-11-25，「检查更新」逐页比对用）。
///
/// 为什么比指纹、不比 HTML 原文：站点每页都带随机会话串 / 时间戳之类的东西，
/// 逐字比会永久判「有变化」。所以只取**解析之后的内容**：
/// 标题、分类、每楼的 pid / 楼号 / 作者 / 时间 / 正文 / 引用 / 图片 / 点评 / 评分 / 投票。
///
/// ⚠ 刻意**不含** `views` / `replies`：浏览数每看一次就涨一个，含进去等于每页
/// 永远「有变化」。回复数变化会体现在「总页数」与末页楼层上，另有出口。
///
/// 结果是 FNV-1a 64 的十六进制串，只用于相等比较，不进 UI。
String forumPageFingerprint(ForumThreadPage data) {
  final buf = StringBuffer()
    ..write('T|')
    ..write(data.title)
    ..write('|')
    ..write(data.tag)
    ..write('\n');
  for (final post in data.posts) {
    buf
      ..write('P|')
      ..write(post.pid)
      ..write('|')
      ..write(post.floor)
      ..write('|')
      ..write(post.author)
      ..write('|')
      ..write(post.authorUid)
      ..write('|')
      ..write(post.time)
      ..write('\n');
    for (final block in post.blocks) {
      buf
        ..write('B|')
        ..write(_blockText(block))
        ..write('\n');
    }
    for (final img in post.images) {
      buf
        ..write('I|')
        ..write(img)
        ..write('\n');
    }
    for (final c in post.comments) {
      buf
        ..write('C|')
        ..write(c.author)
        ..write('|')
        ..write(c.time)
        ..write('|')
        ..write(c.text)
        ..write('\n');
    }
    final rate = post.rate;
    if (rate != null) {
      buf
        ..write('R|')
        ..write(rate.people)
        ..write('|')
        ..write(rate.score);
      for (final item in rate.items) {
        buf
          ..write('|')
          ..write(item.name)
          ..write(',')
          ..write(item.delta)
          ..write(',')
          ..write(item.reason);
      }
      buf.write('\n');
    }
    final poll = post.poll;
    if (poll != null) {
      buf
        ..write('V|')
        ..write(poll.info)
        ..write('|')
        ..write(poll.end)
        ..write('|')
        ..write(poll.options.join(','))
        ..write('\n');
    }
  }
  return _fnv1a64(buf.toString());
}

/// 块级内容拍平成一行文本（引用 / 图 / 分割线 / 折叠 / 附件都进指纹）。
String _blockText(ForumBlock block) {
  switch (block) {
    case ForumParaBlock(:final inlines):
      return 'para:${inlines.map((e) => e.text).join()}';
    case ForumQuoteBlock(:final quote):
      return 'quote:${quote.author}|${quote.time}|${quote.text}';
    case ForumImageBlock(:final url, :final originalUrl, :final caption):
      return 'img:$url|$originalUrl|$caption';
    case ForumDividerBlock():
      return 'hr';
    case ForumCollapseBlock(:final title, :final blocks):
      return 'fold:$title{${blocks.map(_blockText).join('¦')}}';
    case ForumAttachmentBlock(:final items):
      return 'att:${items.map((e) => '${e.name}|${e.size}|${e.href}').join('¦')}';
  }
}

String _fnv1a64(String input) {
  var h = 0xcbf29ce484222325;
  for (final b in utf8.encode(input)) {
    h ^= b;
    h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return h.toRadixString(16).padLeft(16, '0');
}
