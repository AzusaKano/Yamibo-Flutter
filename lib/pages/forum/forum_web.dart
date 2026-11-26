import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/forum/forum_api.dart' show resolveFindpost;
import '../../data/forum/forum_http.dart' show ForumHttp, kForumBase, kForumMobileUa;
import '../../data/forum/forum_auth.dart' show ForumSession;
import '../../data/http.dart' show YmHttpError;
import '../../data/native_bridge.dart' show YmNative;
import '../routes.dart' show ymPush;
import '../../dev/metrics.dart' show ymBeginProbe;
import '../../design/ym_route.dart' show ymRoute;
import '../../design/widgets/toast.dart' show showYmToast;
import '../web_page.dart';
import 'forum_board_page.dart';
import 'forum_login_page.dart' show ForumLoginPage;
import 'forum_thread_page.dart';

/// D 网页壳（论坛侧统一出口）：WebPage 配上移动 UA + 论坛罐，
/// 再加一层**原生链接路由**——网页里点到的帖子 / 板块链接不留在网页里，
/// 拦下来用原生页打开（收藏列表 / 提醒页里点帖 → 原生阅读，App 界面一套）。
///
/// 口径：列表类页面（收藏 / 提醒 / 站方自研打卡等没有原生件的）留在网页；
/// **帖子与板块**这类已有原生屏的，从网页里点进也回原生（落地方案 §1：
/// 客户端做「逛 + 看」，收藏列表暂无原生化计划——那需要登录态页面样本）。

/// 打开论坛网页壳。[routeNative] = 网页里点到的帖子 / 板块链接用原生页打开。
/// 返回路由 Future：调用方可 await「用户从网页回来」再做后续动作
///（如完成验证后自动重试——这类验证只在浏览器引擎里能完成）。
///
/// ⚠ 定位（2026-11 第六期拍板，防后人好心补做）：网页壳是「一页过渡」，
/// 返回（含 Android 14+ 预测式返回手势）**直接关页面**，不做「返回上一条
/// 网页历史」——回退历史会拖长返回路径；WebView 内部历史不参与路由栈。
/// [onNativeLink] 是「主框架导航判定」的**自定义**版本（0.1.38 加法参数）：
/// 传了就用它、不传仍按 [routeNative] 走原有 [_routeNative]。回帖表单页要
/// 认出「提交成功后被服务端带回帖页」这一刻（见 [openForumReplyPage]），
/// 只能自己拿判定回调，所以这里放开一层；默认行为一字不变。
Future<void> openForumWeb(
  BuildContext context, {
  required String path,
  required String title,
  bool routeNative = true,
  bool Function(Uri uri)? onNativeLink,
}) {
  ymBeginProbe('route', '路由 → 首帧完成');
  return Navigator.of(context).push(_forumWebRoute(
    path: path,
    title: title,
    onNativeLink: onNativeLink ?? (routeNative ? (uri) => _routeNative(context, uri) : null),
  ));
}

/// 网页壳路由的构造（[openForumWeb] 与 [openForumReplyPage] 共用）：
/// 后者要拿 route 判「我还在栈顶吗」，所以单独抽一层，不复制粘贴 WebPage 参数。
Route<void> _forumWebRoute({
  required String path,
  required String title,
  bool Function(Uri uri)? onNativeLink,
}) {
  return ymRoute(WebPage(
    url: '$kForumBase$path',
    title: title,
    userAgent: kForumMobileUa,
    cookieHeader: ForumSession.cookieHeader(),
    onNativeLink: onNativeLink,
    // WebView 页不吃快照（快照不支持平台视图），转场/预测返回期间实时绘制。
  ), snapshot: false);
}

/// 挑战层错误态的唯一出口（0.1.19 用户拍板：收束成一个「去验证」按钮）：
/// 打开网页壳 → WebView 里完成站点要求的验证 → **探通就自动关页** →
/// 调用方 await 返回后自动重试。
///
/// 为什么判据是「探通」而不是「Cookie 值变了」：挑战层只能由浏览器引擎处理，
/// 原生请求拿不到新的凭据。未完成验证时 WebView 罐里的值可能仍是上一轮的旧
/// 凭据，此时关页等于拿废证去重试；而凭据本来就有效时值又不会变化，判据永远
/// 不成立。所以轮询到罐里有值后，借它发一页真请求（[forumWafPassUsable]），
/// 探通了才自动 pop。每 ~3s 探一次、总窗 ~30s。凭据本身有时效，过期后仍需重新
/// 走这一页。
///
/// 0.1.22 真机实证过上述两种误判（快照竞态导致过早关页 / 有效时不关页），
/// 探通是唯一可靠的判据。
/// 超时后停止轮询、网页留着（验证页通常仍会自行跳转，用户手动返回也一样
/// 触发重试，流程不会卡死）。
Future<void> openForumWafVerifyPage(BuildContext context) async {
  final nav = Navigator.of(context);
  final route = ymRoute(WebPage(
    url: '$kForumBase/forum.php?mobile=2',
    title: '论坛',
    userAgent: kForumMobileUa,
    cookieHeader: ForumSession.cookieHeader(),
    // 验证页只为过挑战：不挂原生链接路由（点进帖子会把本页压在底下，
    // 自动关页的「只在验证页在顶时 pop」判定就失焦了）
    onNativeLink: null,
    // WebView 页不吃快照，同 openForumWeb。
  ), snapshot: false);
  final popped = nav.push<void>(route);
  var done = false;
  var probing = false;
  var lastProbeAt = 0;
  final poll = Timer.periodic(const Duration(milliseconds: 600), (t) async {
    if (done || probing) return;
    if (t.tick > 50) {
      // ~30s 超时：停止轮询，页面留给用户；手动返回后调用方照常重试
      t.cancel();
      done = true;
      return;
    }
    // 罐里还没有凭据（验证未完成 / 未下发）就不用探
    if (forumWafPassValue(await _webviewCookie()).isEmpty) return;
    // 探测节流 ~3s：探测本身走 ForumHttp 单车道 + 失败重试，别把它打满
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - lastProbeAt < 3000) return;
    lastProbeAt = nowMs;
    probing = true;
    try {
      final usable = await forumWafPassUsable();
      if (done) return;
      if (usable) {
        t.cancel();
        done = true;
        // 探通：自动关页。用户若已从本页点开别的页（isCurrent=false），
        // 不硬 pop——留着让用户继续逛，手动回来时触发重试
        if (route.isCurrent && nav.canPop()) nav.pop();
      }
    } finally {
      probing = false;
    }
  });
  try {
    await popped;
  } finally {
    done = true;
    poll.cancel();
  }
}

/// 通行证可用性探测（自动关页的硬判据）：发一页真请求——ForumHttp 被拦时会
/// **自动借 WebView 罐里的新证重放一次**（forum_http.dart），所以这里返回 true
/// 就代表「当前 WebView 的通行证对原生请求真的有效」。测试注入 debugHandler。
Future<bool> forumWafPassUsable() async {
  try {
    await ForumHttp.instance.request('/forum.php?mobile=2');
    return true;
  } catch (_) {
    // 验证未完成 / 网络失败 / 登录门：探不通，继续等验证完成（登录门属于罐里
    // 没登录态，与凭据无关，同样继续等——验证页的目标只是原生请求能通）
    return false;
  }
}

/// 帖子页网页壳地址（mobile=2 硬口径）。带 [anchorPid] 时附楼层锚点，
/// WebView 落地就停在那楼——「回复按楼定位」（0.1.22 反馈）用它。
String forumThreadWebPath(String tid, {int page = 1, String? anchorPid}) {
  final anchor =
      (anchorPid == null || anchorPid.isEmpty) ? '' : '#pid$anchorPid';
  return '/forum.php?mod=viewthread&tid=$tid&page=$page&mobile=2$anchor';
}

/// WebView 里 bbs 域的 Cookie 串（通道不可用如测试环境给空串，轮询自然超时）。
Future<String> _webviewCookie() async {
  try {
    return await YmNative.cookie('$kForumBase/');
  } catch (_) {
    return '';
  }
}

/// 从 Cookie 串里取 WAF 通行证指纹（`name=value`；没有给空串）。
/// 轮询用它预判「罐里有没有通行证」，有才值得发探测请求（见 forumWafPassUsable）。
String forumWafPassValue(String header) {
  for (final name in const ['acw_sc__v2', 'nox_jst_v1']) {
    final m = RegExp('$name=([^;]+)').firstMatch(header);
    if (m != null) return '$name=${m.group(1)}';
  }
  return '';
}

/// 回帖表单页地址（0.1.38）。形态照抄 6 个本地实抓样本，别自己改参数顺序：
/// `forum.php?mod=post&action=reply&fid=<板块号>&tid=<帖号>[&repquote=<楼pid>]&page=1&mobile=2`
///
/// - [pid] 传了 = 回复**某一楼**：站点楼层「回复」按钮用的参数是 `repquote`
///   （会带被回复楼的引用块，`reppid` / `reppost` 隐藏字段服务端自己补）；
///   旧口径用 `reppost` 只会写隐藏字段、页面看起来仍是主题回复；
/// - 不传 = 主题级回复：底部回复条走这条；
/// - [fid] 空 = 这个参数整个不带（站点按 tid 自己认），不编板块号。
String forumReplyPath({
  required String tid,
  String fid = '',
  String? pid,
  int page = 1,
}) {
  final buf = StringBuffer('/forum.php?mod=post&action=reply');
  if (fid.isNotEmpty) buf.write('&fid=$fid');
  buf.write('&tid=$tid');
  if (pid != null && pid.isNotEmpty) buf.write('&repquote=$pid');
  buf.write('&page=$page&mobile=2');
  return buf.toString();
}

/// 回帖**提交成功**的判据：主框架跳到**同 tid 的帖子页**（服务端 302 落点）。
///
/// 为什么必须判「同 tid」：表单页里也有帖子链接，一刀切「跳到帖子页就算提交成功」
/// 会把「在表单页里点链接看一眼帖子」误判成提交、把表单页关掉。
/// 写操作 URL（`mod=post` 自跳）永远不算成功 —— 见 [forumIsWriteAction]。
bool forumIsReplyDoneUrl(String url, String tid) {
  if (forumIsWriteAction(url)) return false;
  final target = forumNativeTarget(url);
  if (target == null) return false;
  if (target.kind == 'thread') return target.id == tid;
  // findpost 链接带的是 `ptid`（帖子 id），不是 tid —— 只有同帖才算「回到本帖」
  if (target.kind == 'findpost') return _urlParam(url, 'ptid') == tid;
  return false;
}

/// 提交成功后服务端给的楼层 pid（有就跳到自己那楼）：优先 URL 片段 `#pidN`，
/// 其次 `pid=` 参数；都没给返回空串（调用方只刷新到最新，不编位置）。
String forumReplyDonePid(String url) {
  final hash = RegExp(r'#pid(\d+)').firstMatch(url)?.group(1);
  if (hash != null && hash.isNotEmpty) return hash;
  return _urlParam(url, 'pid');
}

/// 从 URL 里取一个数字参数（同时兼容 `?x=` / `&x=` 与 HTML 里未解码的 `&amp;x=`）。
String _urlParam(String url, String name) {
  final m = RegExp('(?:[?&]|&amp;)$name=(\\d+)').firstMatch(url);
  return m?.group(1) ?? '';
}

/// 写操作 URL 白名单：命中即**不是浏览页**，整页交给网页自己跑。
/// 命中 [forumNativeTarget] 时返回 `null`（不截回原生）。
///
/// 为什么非要这条：这些 URL **全都带 `tid=`**，不先放行就会被判成「打开某个帖子」→
/// `web_page.dart` 的 `onNavigationRequest` 直接 prevent → 网页不加载、原生开帖页。
/// 用户点「发表回复」当场被弹回 App 的原生帖页，回帖永远发不出去（0.1.37 实测死循环）。
///
/// 覆盖（形态以实抓为准，见 [forumReplyPath] 与样本）：
/// - `mod=post` —— 回帖 `action=reply` / 发帖 `newthread` / 编辑 `edit` 的**表单页**；
/// - `mod=misc` —— 评分 `action=rate` / 查看评分 `viewratings` / 举报等杂项动作页；
/// - `action=votepoll` —— 首楼 `<form id="poll">` 的提交地址。
bool forumIsWriteAction(String url) {
  if (url.contains('mod=post')) return true;
  if (url.contains('mod=misc')) return true;
  if (url.contains('action=votepoll')) return true;
  return false;
}

/// 判定一个论坛链接该不该用原生页打开，返回 (kind, id)。
/// - 写操作（回帖表单 / 评分 / 投票提交）→ **先短路返回 null**（留在网页，0.1.38）；
/// - `goto=findpost&pid=N`（跳楼链接，正文 / 引用头里大量出现）→ (findpost, pid)。
///   **必须先于 tid 判定**：它带 `ptid=` 而非 `tid=`，本来不会被下面的规则命中，
///   但口径上它是「跳到某一楼」而不是「打开某个帖子」，要走 resolveFindpost 精准定位；
/// - `viewthread&tid=N` 与 SEO 重写 `thread-N-p-x.html` → (thread, N)
/// - `forumdisplay&fid=N` → (board, N)
/// 其余（收藏 / 提醒 / 打卡 / 首页 / 登录…）返回 null，留在网页。
({String kind, String id})? forumNativeTarget(String url) {
  // 写操作不是浏览页：这里不认领，网页不拦、表单才打得开（0.1.38 用户拍板）
  if (forumIsWriteAction(url)) return null;
  if (url.contains('goto=findpost')) {
    final pid = RegExp(r'[?&]pid=(\d+)').firstMatch(url)?.group(1);
    if (pid != null && pid.isNotEmpty) return (kind: 'findpost', id: pid);
  }
  final tid = RegExp(r'[?&]tid=(\d+)').firstMatch(url)?.group(1) ??
      RegExp(r'thread-(\d+)-\d+').firstMatch(url)?.group(1);
  if (tid != null && tid.isNotEmpty) return (kind: 'thread', id: tid);
  final fid = RegExp(r'[?&]fid=(\d+)').firstMatch(url)?.group(1);
  if (fid != null && fid.isNotEmpty) return (kind: 'board', id: fid);
  return null;
}

/// 正文 / 引用头里的 findpost 链接统一原生出口（0.1.22 用户拍板 A 路线）：
/// 原生请求 findpost 重定向，拿服务端算好的 tid + 页码（见 resolveFindpost），
/// 直接开原生帖子页到那一页并滚到那一楼。游客锁板块带去原生登录页；
/// 其余失败给人话提示（不静默）。
Future<void> openForumFindpost(BuildContext context, String pid) async {
  try {
    final target = await resolveFindpost(pid);
    if (!context.mounted) return;
    ymPush(
      context,
      ForumThreadPage(
        tid: target.tid,
        initialPage: target.page,
        anchorPid: pid,
        // 显式楼层优先：不恢复历史、不弹「已回到上次阅读」（用户点的是某一楼）。
        restoreProgress: false,
      ),
    );
  } on YmHttpError catch (e) {
    if (!context.mounted) return;
    if (e.code == 'LOGIN_REQUIRED') {
      await Navigator.of(context).push(ymRoute(const ForumLoginPage(), snapshot: false));
      return;
    }
    showYmToast(context, e.message);
  }
}

/// 正文链接的原生出口（帖子页楼层卡与论坛阅读器共用同一套判定）：
/// findpost → 精准跳楼；帖子 / 板块 → 原生页；其余 → 网页壳。
/// 行为就是帖子页 `_openLink` 原有的三分支，抽出来只为阅读器不另写一份。
void openForumBodyLink(BuildContext context, String href) {
  final target = forumNativeTarget(href);
  if (target != null) {
    switch (target.kind) {
      case 'findpost':
        unawaited(openForumFindpost(context, target.id));
      case 'thread':
        ymPush(context, ForumThreadPage(tid: target.id));
      default:
        ymPush(context, ForumBoardPage(fid: target.id, name: ''));
    }
    return;
  }
  unawaited(openForumLink(context, href));
}

/// 正文里的普通链接出口：bbs 站内 → 网页壳（罐 + 移动 UA + 原生链接路由都保留）；
/// 外站 → 朴素 WebPage（不塞论坛 Cookie，UA 用阅读侧默认）。
Future<void> openForumLink(BuildContext context, String href) async {
  final uri = Uri.tryParse(href);
  if (uri == null || !uri.hasScheme) return;
  if (uri.host == Uri.parse(kForumBase).host) {
    var path = href.startsWith(kForumBase) ? href.substring(kForumBase.length) : href;
    if (!path.contains('mobile=')) {
      path += path.contains('?') ? '&mobile=2' : '?mobile=2';
    }
    await openForumWeb(context, path: path, title: '百合会论坛');
  } else {
    await Navigator.of(context).push(ymRoute(WebPage(url: href, title: '外部链接'), snapshot: false));
  }
}

/// 回复入口（0.1.38 用户拍板）：**直接开回帖表单页**，提交成功后自动关页、回到原帖。
///
/// 旧路径是「再开一遍浏览页，让用户自己在网页里找『发表回复』按钮」——第二步正好撞上
/// 写操作被截回原生的死循环（0.1.37 实测），用户实际上发不出帖。
///
/// 完成判据用 [forumIsReplyDoneUrl]（同 tid 的帖子页 = 提交成功后面包屑回来的地方）：
/// - 命中 → 立刻 `prevent`（别让网页再加载一遍帖页）；下一帧关掉网页壳、回调调用方刷新原帖；
/// - 其余链接（表单页里的普通链接 / 游客点的登录页）→ 交回 [_routeNative]。
///
/// [pid] 传了 = 回复某一楼（`repquote`）；不传 = 主题级回复。
/// [onSubmitted] 拿到的是「服务端给的楼层 pid」，拿不到就是空串（能跳就跳，不能就只刷新）。
Future<void> openForumReplyPage(
  BuildContext context, {
  required String tid,
  String fid = '',
  String? pid,
  int page = 1,
  required String title,
  void Function(String pid)? onSubmitted,
}) {
  final nav = Navigator.of(context);
  var submitted = false;
  late final Route<void> route;
  route = _forumWebRoute(
    path: forumReplyPath(tid: tid, fid: fid, pid: pid, page: page),
    title: title,
    onNativeLink: (uri) {
      if (!forumIsReplyDoneUrl(uri.toString(), tid)) {
        return _routeNative(context, uri);
      }
      // 已经提交过（同一次回帖里 302 连带触发两次导航）：只拦不重复关页
      if (submitted) return true;
      submitted = true;
      final targetPid = forumReplyDonePid(uri.toString());
      // 延迟一帧再关页：此刻还在 WebView 的导航回调里，当场 pop 会把
      // WebViewController 在它自己的回调栈上 dispose（平台通道会报错）。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // 用户已经自己从网页壳点开别的页（本页不在栈顶）就不硬 pop，
        // 也不刷新底下那层——他手上那页才是当前上下文
        if (!route.isCurrent) return;
        if (nav.canPop()) nav.pop();
        onSubmitted?.call(targetPid);
      });
      return true;
    },
  );
  return nav.push<void>(route);
}

bool _routeNative(BuildContext context, Uri uri) {
  final target = forumNativeTarget(uri.toString());
  if (target == null) return false;
  switch (target.kind) {
    case 'findpost':
      // 不 await：网页壳压在底下，跳楼页开它自己的
      unawaited(openForumFindpost(context, target.id));
    case 'thread':
      ymPush(context, ForumThreadPage(tid: target.id));
    default:
      // name 留空：板块页自己从 HTML 解析板块名
      ymPush(context, ForumBoardPage(fid: target.id, name: ''));
  }
  return true;
}
