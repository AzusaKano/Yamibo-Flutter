/// 论坛写操作（**仅一件**：收藏帖子）。打卡 / 回帖 / 发帖 / 评分 / 投票一律开网页。
///
/// 口径（落地方案 §1、§6）：
/// - **写入类请求绝不重放**：`ForumHttp` 对 POST 只发一次、不重试，这里也不做任何补偿重发；
/// - 失败不静默：每个失败路径都给人话 + 可以重试（重试 = 用户再点一次，发起新请求）；
/// - formhash 是写操作令牌，从页面取：
///   收藏 POST `home.php?mod=spacecp&ac=favorite&type=thread&id=<tid>&mobile=2`
///   `&handlekey=favbtn&inajax=1`，表单 `favoritesubmit=true&formhash=<hash>`
///   （站内帖子页自己的 JS 就是这么发的）；游客 GET 会 302 跳登录。
///
/// **打卡为什么不在 App 级做**（0.1.16 用户拍板，两轮真机实测的结论）：
/// 1. 打卡插件是站方的 **zqlj_sign**（入口 `plugin.php?id=zqlj_sign&mobile=2`），
///    常见 Discuz 打卡插件全部「插件不存在」；该页对直连请求返回防护层响应，
///    登录态 App 通道同样被拦——原生请求过不去，只有网页壳里的 WebView 能自动
///    完成验证；
/// 2. 打卡页带「已连续打卡 N 天」等统计文案，按关键词判「已打卡」必然误报。
/// 所以打卡 = 「我的论坛」按钮直接开 zqlj_sign 网页壳，用户在站内点。
/// 将来若站方放开接口可再启用原生实现。
library;

import '../http.dart' show YmHttpError;
import 'forum_auth.dart' show forumPageSaysGuest;
import 'forum_http.dart' show ForumHttp, kForumBase;
import 'forum_parser.dart' show formhash, stripTags;

/// 一次写操作的结果。界面按 [kind] 给人话，[message] 是可以直接显示的句子。
class ForumWriteResult {
  const ForumWriteResult._(this.kind, this.message);

  final ForumWriteKind kind;
  final String message;

  factory ForumWriteResult.success(String message) =>
      ForumWriteResult._(ForumWriteKind.success, message);
  factory ForumWriteResult.already(String message) =>
      ForumWriteResult._(ForumWriteKind.already, message);
  factory ForumWriteResult.loginRequired([String message = '要先登录论坛账号才能使用。']) =>
      ForumWriteResult._(ForumWriteKind.loginRequired, message);
  factory ForumWriteResult.failed(String message) =>
      ForumWriteResult._(ForumWriteKind.failed, message);
}

enum ForumWriteKind { success, already, loginRequired, failed }

/// 收藏一个帖子。返回 [ForumWriteResult]，调用方据此提示（成功后不用刷新页面）。
Future<ForumWriteResult> favoriteThread(String tid) async {
  if (tid.isEmpty) return ForumWriteResult.failed('这个条目没有帖子号，收藏不了。');
  try {
    // ① 拿令牌：帖子页里就有 formhash（游客页也印）
    final page = await ForumHttp.instance.request(
      '/forum.php?mod=viewthread&tid=$tid&mobile=2',
      referer: '$kForumBase/forum.php?mod=viewthread&tid=$tid&mobile=2',
    );
    if (forumPageSaysGuest(page.body)) {
      // 帖子本身要登录才能看 → 一定也没法收藏
      return ForumWriteResult.loginRequired('要先登录论坛账号才能收藏。');
    }
    final hash = formhash(page.body);
    if (hash.isEmpty) {
      return ForumWriteResult.failed('页面上没拿到收藏令牌，请稍后再试。');
    }

    // ② 提交收藏（写入类：只发一次，不重试）
    final res = await ForumHttp.instance.requestForm(
      '/home.php?mod=spacecp&ac=favorite&type=thread&id=$tid&mobile=2'
      '&handlekey=favbtn&inajax=1',
      <String, String>{'favoritesubmit': 'true', 'formhash': hash},
      referer: '$kForumBase/forum.php?mod=viewthread&tid=$tid&mobile=2',
    );
    return _judgeFavorite(res.body);
  } on YmHttpError catch (e) {
    if (e.isLoginRequired) return ForumWriteResult.loginRequired();
    // 验证类错误不重复缀「稍后再试」（e.message 本身就是这句话）
    return ForumWriteResult.failed(
        e.code == 'WAF' ? '${e.message}。' : '${e.message}，稍后再试一次。');
  } catch (_) {
    return ForumWriteResult.failed('网络不给力，稍后再试一次。');
  }
}

/// 收藏响应判定。inajax 的成功 / 失败消息都包在 XML 里，剥出文本按关键词分：
/// 「成功」= 收藏成功；「已经收藏」= 重复收藏（给「已经收藏过」而不是报错）；
/// 其余原文给出来。空响应 = 游客态被拦（实测游客 POST 返回 200 + 空 body）。
ForumWriteResult _judgeFavorite(String body) {
  final text = stripTags(body.replaceAll(RegExp(r'<!\[CDATA\[|\]\]>'), ' '));
  if (text.isEmpty) return ForumWriteResult.loginRequired();
  if (text.contains('成功')) return ForumWriteResult.success('收藏成功，可以在「我的论坛」里看到。');
  if (text.contains('已经收藏') || text.contains('已收藏')) {
    return ForumWriteResult.already('已经收藏过这个帖子了。');
  }
  if (text.contains('登录') && text.contains('提示')) return ForumWriteResult.loginRequired();
  return ForumWriteResult.failed(text.isEmpty ? '站点没有给明确答复，稍后再试。' : '收藏没有成功：$text');
}
