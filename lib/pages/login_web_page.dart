import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../data/auth.dart';
import '../data/http.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../design/widgets/load_bar.dart';
import '../design/widgets/top_bar.dart';

/// 站内网页登录（WebView）。
///
/// 口径与 uni 版 `pages/login-web/login-web.vue` 一致：
/// - 页面里输入账号密码，**客户端不接触密码**；这里只负责把 Cookie 取回来；
/// - 每次页面加载完校验一次 `/my`，成功就取 Cookie 并退回账号页；
/// - 物理返回 = 放弃登录，只把 WebView 现有的 Cookie 同步一次，不做站内注销。
///
/// ⚠ 必须用 PC UA：站点按 UA 返两套模板，手机模板的表单结构与 `parseMyPage`
/// 的判定对不上（解析器只认 PC 模板的 `LoginForm[username]`）。
class LoginWebPage extends StatefulWidget {
  const LoginWebPage({super.key, this.initialUrl = YmAuth.loginUrl});

  final String initialUrl;

  @override
  State<LoginWebPage> createState() => _LoginWebPageState();
}

class _LoginWebPageState extends State<LoginWebPage> {
  late final WebViewController _controller;

  bool _firstPageDone = false;
  bool _checking = false;
  bool _done = false;
  bool _queued = false;
  String? _error;

  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(kYmPcUa)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: _onPageFinished,
          onWebResourceError: (e) {
            if (e.isForMainFrame != true) return;
            if (_firstPageDone || !mounted) return;
            setState(() {
              _error = '页面没能打开：${e.description}';
            });
          },
        ),
      );
    _controller.loadRequest(Uri.parse(widget.initialUrl));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onPageFinished(String url) {
    if (!mounted) return;
    if (!_firstPageDone) setState(() => _firstPageDone = true);
    // 站内登录会 302 到别的站内页面，跳转过程会连触发多次加载
    if (!url.contains('yamibo.com')) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _verify);
  }

  /// 校验一次登录态。成功就关页；失败留在网页里（可能还在登录表单上）。
  Future<void> _verify() async {
    if (_done || !mounted) return;
    if (_checking) {
      // 校验途中又有页面加载完，等这次结果回来再补一次
      _queued = true;
      return;
    }
    _checking = true;
    try {
      final acc = await YmAuth.checkLogin();
      if (!mounted) return;
      if (acc.loggedIn) {
        _done = true;
        Navigator.of(context).pop(true);
        return;
      }
    } catch (e) {
      // 校验失败先留在网页里，用户仍可用返回键退出
      if (mounted) setState(() => _error = '登录状态没能确认：$e');
    } finally {
      _checking = false;
      if (_queued) {
        _queued = false;
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 250), _verify);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) return;
        // 放弃登录：把 WebView 现有的 Cookie 同步一次，账号页回来会重新校验
        unawaited(YmAuth.pullWebviewCookie());
      },
      child: Scaffold(
        body: Column(
          children: [
            const YmTopBar(leading: YmBackButton(), title: '登录'),
            if (!_firstPageDone) const YmLoadBar(),
            Expanded(child: WebViewWidget(controller: _controller)),
            if (_error != null)
              Container(
                width: double.infinity,
                color: c.fillPlain,
                padding: const EdgeInsets.fromLTRB(YmLayout.pagePad, 10, YmLayout.pagePad, 10),
                child: Text(
                  _error!,
                  style: TextStyle(
                    fontSize: YmFont.small12,
                    height: 1.5,
                    color: c.text2,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
