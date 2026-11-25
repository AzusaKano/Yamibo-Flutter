import 'api.dart';
import 'http.dart';
import 'native_bridge.dart';
import 'session.dart';

/// 登录流程（唯一入口），对齐 uni 版 `services/auth.js`。
///
/// 口径：
/// - 只在站内网页输入账号密码，**客户端不接触密码**，也不做验证码绕过；
/// - 登录完成后只同步 Cookie：从 WebView 的 Cookie 库读回（原生桥），注入后续请求；
/// - 登录态以 `/my` 的真实返回为准，不用本地标记自说自话；
/// - 退出登录 = 站内注销（`POST /user/logout`）+ 清本地 + 清 WebView Cookie。
///   只清本地会让站内会话继续有效，下次登录**换不了账号**（uni 版 2026-10-23 实测）。
class YmAuth {
  YmAuth._();

  /// 站内登录页。必须用 PC UA 打开：站点按 UA 返两套模板，PC 模板才有
  /// `LoginForm[username]`（见 `parseMyPage` 的判定口径）。
  static const String loginUrl = 'https://www.yamibo.com/user/login';

  /// 清 Cookie 时覆盖的域。本客户端只访问这四个
  /// （论坛 `bbs` 是第二期加的：论坛登录态也在 WebView 的 Cookie 库里，
  /// 退出登录「两份一起清」就要连它一起枚举置空）。
  static const List<String> webviewCookieUrls = <String>[
    'https://www.yamibo.com',
    'https://m.yamibo.com',
    'https://img.yamibo.com',
    'https://bbs.yamibo.com',
  ];

  /// 从 WebView 的 Cookie 库取站内会话并入 [YmSession]。
  ///
  /// 登录 WebView 还开着时也能取到（同一个 Cookie 库）；登录页据此判断是否已完成登录。
  /// 返回是否真的取到了 cookie。
  static Future<bool> pullWebviewCookie() async {
    final raw = await YmNative.cookie('https://www.yamibo.com');
    if (raw.isEmpty) return false;
    // 站内可能换过 PHPSESSID，以 WebView 里那份为准
    YmSession.absorbCookieHeader(raw, replace: true);
    return true;
  }

  /// 校验登录态：`/my` 出现登录表单即视为未登录。
  ///
  /// 网络异常会抛出（由页面显示错误），**不静默改成游客**——否则一次断网就把用户踢下线。
  /// [useWebviewCookie] 为 true 时先取一次 WebView 的 Cookie（App 侧才有意义）。
  static Future<YmAccount> checkLogin({
    bool useWebviewCookie = true,
    bool retry = true,
  }) async {
    if (useWebviewCookie) await pullWebviewCookie();

    final YmMyPage page;
    try {
      page = await fetchMy(retry: retry);
    } on YmHttpError catch (e) {
      // `/my` 直接 302 到登录页 ⇒ 会话已经不在了
      if (e.isLoginRequired) {
        await _forgetAccount();
        return YmSession.account.value;
      }
      rethrow;
    }

    if (!page.info.loggedIn) {
      await _forgetAccount();
      return YmSession.account.value;
    }

    final prev = YmSession.account.value;
    final now = DateTime.now().millisecondsSinceEpoch;
    final next = YmAccount(
      loggedIn: true,
      name: page.info.name.isNotEmpty ? page.info.name : prev.name,
      uid: page.info.uid.isNotEmpty ? page.info.uid : prev.uid,
      at: prev.loggedIn ? prev.at : now,
      checkedAt: now,
    );
    await YmSession.apply(next);
    // 匿名时取到的页可能与登录后不同（排序/热度/书架），换态就作废缓存
    if (!prev.loggedIn) clearCache();
    return next;
  }

  /// 本地会话超过 [maxAge] 才回站校验，避免每次进页面都发请求。
  static Future<YmAccount> refreshIfStale({
    Duration maxAge = const Duration(seconds: 60),
    bool useWebviewCookie = false,
  }) async {
    final acc = YmSession.account.value;
    if (!acc.loggedIn) return acc;
    final age = DateTime.now().millisecondsSinceEpoch - acc.checkedAt;
    if (age < maxAge.inMilliseconds) return acc;
    return checkLogin(useWebviewCookie: useWebviewCookie);
  }

  /// 启动时用：**只在本地看起来已登录时**才回站校验，游客不发请求。
  static Future<YmAccount> verifyOnLaunch() async {
    final acc = YmSession.account.value;
    if (!acc.loggedIn) return acc;
    try {
      return await checkLogin(useWebviewCookie: true, retry: false);
    } catch (_) {
      // 断网/站点抽风：保持本地登录态，不把人踢下线
      return YmSession.account.value;
    }
  }

  /// 退出登录。返回站点是否确认注销（失败不抛，由界面提示）。
  ///
  /// **顺序不能反**：站内注销要用当前 Cookie 与 CSRF，先注销再清本地。
  static Future<bool> logout() async {
    // 用 WebView 里最新的 Cookie：本地存的那份可能是登录当时取的，
    // 站点换过 PHPSESSID 就失效了
    await pullWebviewCookie();

    var remote = false;
    try {
      final page = await fetchMy(retry: false);
      if (!page.info.loggedIn) {
        // 本来就没登录：站内没有会话可注销，目的已达成
        remote = true;
      } else if (page.csrf.isEmpty) {
        remote = false;
      } else {
        await YmHttp.instance.requestForm('/user/logout', <String, String>{
          '_csrf-frontend': page.csrf,
        });
        remote = true;
      }
    } on YmHttpError catch (e) {
      // `/my` 直接 302 到登录页，说明会话已经不在了
      remote = e.isLoginRequired;
    } catch (_) {
      remote = false;
    }

    await YmSession.clear();
    clearCache();
    await clearWebviewCookies();
    return remote;
  }

  /// 清 WebView 的 Cookie 库。
  ///
  /// ⚠ 只清本地不够：登录页用的是系统 WebView 的 Cookie 库，残留的 `PHPSESSID`
  /// 会让登录页直接判定已登录、无法切换账号。
  static Future<int> clearWebviewCookies() async {
    return YmNative.clearCookies(webviewCookieUrls);
  }

  static Future<void> _forgetAccount() async {
    final had = YmSession.account.value;
    await YmSession.markLoggedOut();
    if (had.loggedIn) clearCache();
  }
}
