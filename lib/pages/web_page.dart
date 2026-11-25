import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../data/forum/forum_http.dart' show kForumMobileUa;
import '../data/http.dart';
import '../data/native_bridge.dart';
import '../data/session.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../design/widgets/load_bar.dart';
import '../design/widgets/top_bar.dart';
import '../design/widgets/toast.dart';

/// 站内网页（只读）：详情页右上角那枚地球图标打开的就是这里。
///
/// 用途：客户端没做原生实现、或做不好的那些站内动作（评分 / 章评 / 打赏 / 关注作者 /
/// 举报），以及「我就想看看网站上这一页长什么样」。客户端**不在网页里做任何注入**，
/// 页面完全按站点自己的样子跑。
///
/// ⚠ 必须**先把会话 Cookie 灌进 WebView 再 loadRequest**：客户端唯一持有会话的地方是
/// [YmSession] 的 Cookie 罐（`PHPSESSID` 是 HttpOnly，网页里的 `document.cookie` 也拿不到），
/// 不灌就是匿名页 —— 用户明明登录着却看到「请登录」，比不做还糟。
///
/// ⚠ 用 PC UA：站点按 UA 返两套模板，移动模板会把正文挤成一列小字，
/// 跟 App 里其它页面的排版完全是两回事（登录页出于解析口径也是 PC UA）。
///
/// 论坛（bbs.yamibo.com）正好相反：它是 Discuz 手机模板，必须**移动 UA**，
/// 且 Cookie 用论坛那罐（[ForumSession]，www 的 PHPSESSID 在论坛不算登录）。
/// 所以这两项放开成可选参数，阅读侧不传就走原有行为。
class WebPage extends StatefulWidget {
  const WebPage({
    super.key,
    required this.url,
    required this.title,
    this.userAgent,
    this.cookieHeader,
    this.onNativeLink,
  });

  /// 绝对地址（由调用方拼，页面不拼 URL 的规矩在这里也只放宽到「传绝对地址」）。
  final String url;

  /// 顶栏标题，一般是作品名 / 章节名。
  final String title;

  /// 移动 UA（论坛侧传 [kForumMobileUa]）；null = 阅读侧 PC UA。
  final String? userAgent;

  /// 直接发进 WebView 的 Cookie 串（论坛侧传论坛罐的）；null = 用 [YmSession]。
  final String? cookieHeader;

  /// 主框架导航判定：回调返回 true = **不让 WebView 加载**，由调用方自己
  /// 打开原生页（论坛收藏列表里点到帖子 → 用原生帖子页阅读）。回调返回
  /// false 或不传（阅读侧）→ 一切照旧。初始地址不走这个判定。
  final bool Function(Uri uri)? onNativeLink;

  @override
  State<WebPage> createState() => _WebPageState();
}

class _WebPageState extends State<WebPage> {
  late final WebViewController _controller;

  bool _loaded = false;
  String? _error;

  /// 当前地址。页面里跳几下就变了（作品页 → 章节页 → 登录页），
  /// 分享要发的是**眼前这一页**，不是进来时那一页。
  late String _url = widget.url;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(widget.userAgent ?? kYmPcUa)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (req) {
            final judge = widget.onNativeLink;
            if (judge != null &&
                req.isMainFrame != false &&
                req.url != widget.url &&
                judge(Uri.parse(req.url))) {
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onPageFinished: (_) {
            if (mounted && !_loaded) setState(() => _loaded = true);
          },
          onUrlChange: (change) {
            final url = change.url;
            if (url == null || url.isEmpty) return;
            _url = url;
          },
          onWebResourceError: (e) {
            if (e.isForMainFrame != true || !mounted) return;
            setState(() => _error = '页面没能打开：${e.description}');
          },
        ),
      );
    _boot();
  }

  Future<void> _boot() async {
    await _injectCookies();
    if (!mounted) return;
    await _controller.loadRequest(Uri.parse(widget.url));
  }

  /// 把会话 Cookie 逐条写进 WebView 的 Cookie 库。
  ///
  /// 逐条而不是整串：平台接口一次只认一条 `name=value`（Android 侧就是
  /// `CookieManager.setCookie(url, "name=value")`，塞整串会被当成一条畸形 Cookie）。
  /// 单条失败不中断 —— 少一个键最多是少了某项偏好，页面照样能开。
  Future<void> _injectCookies() async {
    final header = widget.cookieHeader ?? YmSession.cookieHeader();
    if (header == null) return;
    final manager = WebViewCookieManager();
    // Cookie 落在**目标页自己的域**上：论坛页传的是论坛罐，得写进 bbs 的域，
    // 不然就是给 www 塞了一堆论坛键（论坛不认，还脏）。
    final host = Uri.parse(widget.url).host;
    final target = host.isNotEmpty ? host : Uri.parse(kYmBase).host;
    for (final part in header.split(';')) {
      final kv = part.trim();
      final eq = kv.indexOf('=');
      if (eq <= 0) continue;
      try {
        await manager.setCookie(
          WebViewCookie(
            name: kv.substring(0, eq).trim(),
            value: kv.substring(eq + 1).trim(),
            domain: target,
          ),
        );
      } catch (_) {
        // 忽略单条失败
      }
    }
  }

  void _reload() {
    setState(() => _error = null);
    _controller.reload();
  }

  /// 分享眼前这一页的链接。
  ///
  /// 优先走系统分享面板（原生桥的 `shareText`）；通道不在（测试 / 桌面端）时降级成
  /// 复制到剪贴板 —— 分享的底线是链接别丢。
  Future<void> _share() async {
    // 网页里可能刚跳转，`_url` 还没来得及更新，以 WebView 自己认的为准
    String url = _url;
    try {
      final live = await _controller.currentUrl();
      if (live != null && live.isNotEmpty) url = live;
    } catch (_) {
      // 拿不到就用上一步记下的
    }
    // 只发链接，不带作品名 —— 这个入口的本意是「用手机上的浏览器接着看这一页」，
    // 分享面板里多一行标题只会干扰粘贴落点。
    final ok = await YmNative.shareText(url);
    if (ok || !mounted) return;

    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    showYmToast(context, '链接已复制');
  }

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return Scaffold(
      body: Column(
        children: [
          YmTopBar(
            leading: const YmBackButton(),
            title: widget.title.isEmpty ? '网页' : widget.title,
            trailing: YmCircleButton(
              // 例外（用户 2026-11-09 拍板）：分享钮保留 Material 图标，自绘版观感不如原版。
              icon: Icon(Icons.share, size: 22, color: c.textStrong),
              semanticLabel: '分享',
              onTap: _share,
            ),
          ),
          if (!_loaded) const YmLoadBar(),
          Expanded(child: WebViewWidget(controller: _controller)),
          if (_error != null)
            Container(
              width: double.infinity,
              color: c.fillPlain,
              padding: const EdgeInsets.fromLTRB(YmLayout.pagePad, 8, YmLayout.pagePad, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _error!,
                      style: TextStyle(fontSize: YmFont.small12, height: 1.5, color: c.text2),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 顶栏换成了分享，刷新能力留在这一行 —— 只在失败态出现，平时不占地方
                  YmTextAction(label: '重试', onTap: _reload),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
