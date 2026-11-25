import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../data/forum/forum_auth.dart';
import '../../data/forum/forum_http.dart' show kForumBase, kForumMobileUa;
import '../../design/theme.dart';
import '../../design/tokens.dart';
import '../../design/widgets/top_bar.dart';

/// 论坛 WebView 登录（D 屏之外的第二种网页壳，登录专用）。
///
/// 口径与阅读侧 `LoginWebPage` 一致，论坛侧的差异只有三处：
/// - **移动 UA**：论坛是 Discuz 手机模板（mobile=2），表单结构与解析口径一致；
/// - Cookie 取回走**论坛罐**（`ForumAuth.pullFromWebview`，前缀 `EeqY_2132_`），
///   与阅读侧 `YmSession` 分开；
/// - 核对依据是页面脚本 `discuz_uid`（'0' = 游客），不是 `/my`。
///
/// 每次页面加载完拉一次 WebView Cookie → 有 `_auth` 就开论坛首页核对 →
/// 确认已登录才落盘退回。物理返回 = 放弃登录，Cookie 同步一次但不强求。
class ForumLoginPage extends StatefulWidget {
  const ForumLoginPage({super.key});

  /// 登录表单页（2026-11-14 实抓：`member.php?mod=logging&action=login&mobile=2`）。
  static const String loginUrl =
      '$kForumBase/member.php?mod=logging&action=login&mobile=2';

  @override
  State<ForumLoginPage> createState() => _ForumLoginPageState();
}

class _ForumLoginPageState extends State<ForumLoginPage> {
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
      ..setUserAgent(kForumMobileUa)
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
    _controller.loadRequest(Uri.parse(ForumLoginPage.loginUrl));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onPageFinished(String url) {
    if (!mounted) return;
    if (!_firstPageDone) setState(() => _firstPageDone = true);
    // 登录跳转会连触发多次加载（302 → 跳回版块），防抖后核对一次
    if (!url.contains('bbs.yamibo.com')) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _verify);
  }

  /// 拉一次 WebView Cookie 核对登录态。成功就关页；失败留在网页里。
  Future<void> _verify() async {
    if (_done || !mounted) return;
    if (_checking) {
      // 核对途中又有页面加载完，等这次结果回来再补一次
      _queued = true;
      return;
    }
    _checking = true;
    try {
      final ok = await ForumAuth.pullFromWebview();
      if (!mounted) return;
      if (ok) {
        _done = true;
        Navigator.of(context).pop(true);
      }
    } catch (_) {
      // 核对失败先留在网页里（可能只是断网），用户仍可用返回键退出
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
        // 放弃登录：把 WebView 现有的 Cookie 同步一次（游客 Cookie 无害，
        // 有 `_auth` 的话下次进论坛也能用），但不当成登录成功
        unawaited(ForumAuth.pullFromWebview());
      },
      child: Scaffold(
        body: Column(
          children: [
            const YmTopBar(leading: YmBackButton(), title: '登录论坛'),
            if (!_firstPageDone)
              LinearProgressIndicator(
                minHeight: 2,
                backgroundColor: c.fillPlain,
                color: c.brand,
              ),
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
