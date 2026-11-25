/// 论坛会话：独立 Cookie 罐 + 账号视图 + 落盘，与阅读侧 `YmSession` 完全隔离。
///
/// 站点事实（落地方案 §2 + 2026-11-14 实抓）：
/// - Cookie 前缀 `EeqY_2132_`，登录态看 `_auth`；
/// - **www 的 `PHPSESSID` 在论坛不算登录**，所以罐子必须独立，绝不混入阅读侧 Cookie；
/// - 权威判定以页面脚本 `discuz_uid`（'0' = 游客）为准，`_auth` 只是内存速判；
/// - WebView 登录后从原生桥取回整串 Cookie（`member.php?mod=logging` 表单域是
///   bbs 自己的域，系统 Cookie 库里 `YmNative.cookie(bbs 首页)` 就能读到）。
///
/// 落盘同 `YmSession` 的路数：`shared_preferences` 依赖 `jni`（本机 NDK 是元数据桩），
/// 目录走原生桥 [YmNative.filesDir]，文件用 `dart:io` 读写。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../native_bridge.dart';
import 'forum_http.dart';
import 'forum_parser.dart' show discuzUid, formhash, forumUserName;

/// 论坛账号视图。字段只保存「站点认给我们的东西」：**不碰账号密码**。
@immutable
class ForumAccount {
  const ForumAccount({
    this.loggedIn = false,
    this.name = '',
    this.uid = '',
    this.checkedAt = 0,
  });

  final bool loggedIn;

  /// 昵称。取不到就空串，界面退「已登录」——不编。
  final String name;
  final String uid;

  /// 最后一次向站点核对的时间（毫秒）。
  final int checkedAt;

  static const ForumAccount none = ForumAccount();

  ForumAccount copyWith({bool? loggedIn, String? name, String? uid, int? checkedAt}) {
    return ForumAccount(
      loggedIn: loggedIn ?? this.loggedIn,
      name: name ?? this.name,
      uid: uid ?? this.uid,
      checkedAt: checkedAt ?? this.checkedAt,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'loggedIn': loggedIn,
        'name': name,
        'uid': uid,
        'checkedAt': checkedAt,
      };

  static ForumAccount fromJson(Map<String, Object?> json) {
    return ForumAccount(
      loggedIn: json['loggedIn'] == true,
      name: (json['name'] as String?) ?? '',
      uid: (json['uid'] as String?) ?? '',
      checkedAt: (json['checkedAt'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ForumAccount &&
        other.loggedIn == loggedIn &&
        other.name == name &&
        other.uid == uid &&
        other.checkedAt == checkedAt;
  }

  @override
  int get hashCode => Object.hash(loggedIn, name, uid, checkedAt);
}

/// 论坛 Cookie 罐：name → value。只保留 name=value，属性（域/路径/过期）忽略。
/// 与 [YmSession] 同款实现（见 `data/session.dart` 的注释），只是不共享状态。
class ForumSession {
  ForumSession._();

  static final Map<String, String> _jar = <String, String>{};

  /// 账号视图。页面用 `ValueListenableBuilder` 或 `addListener` 订阅。
  static final ValueNotifier<ForumAccount> account =
      ValueNotifier<ForumAccount>(ForumAccount.none);

  static bool _loaded = false;

  static bool get loggedIn => account.value.loggedIn;

  static bool get loaded => _loaded;

  /// 会话文件名（论坛独立一份，与阅读侧 `ym_session.json` 分开）。
  static const String _fileName = 'forum_session.json';

  static File? _file;

  static Future<File?> _sessionFile() async {
    final cached = _file;
    if (cached != null) return cached;
    final dir = await YmNative.filesDir();
    if (dir == null || dir.isEmpty) return null;
    return _file = File('$dir${Platform.pathSeparator}$_fileName');
  }

  /// 启动时调用（main.dart）：把上次的 Cookie 与账号视图读回来。
  /// 读不到（首启 / 通道缺失 / 文件损坏）就当游客，**不抛错**。
  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = await _sessionFile();
      if (file == null || !await file.exists()) return;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return;
      final json = jsonDecode(raw);
      if (json is! Map<String, Object?>) return;
      final cookie = json['cookie'];
      if (cookie is String && cookie.trim().isNotEmpty) {
        absorbCookieHeader(cookie);
      }
      final user = json['user'];
      if (user is Map<String, Object?>) {
        account.value = ForumAccount.fromJson(user);
      }
    } catch (_) {
      // 坏档不影响启动：当游客，下一次登录会覆盖
    }
  }

  /// 落盘（异步，失败不影响内存态）。登录成功 / 退出后调用。
  static Future<void> save() async {
    try {
      final file = await _sessionFile();
      if (file == null) return;
      final payload = <String, Object?>{
        'cookie': cookieHeader() ?? '',
        'user': account.value.toJson(),
      };
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(payload), flush: true);
    } catch (_) {
      // 写失败只影响「下次启动要不要重新登录」，不阻塞当前会话
    }
  }

  /// 发给论坛的 `Cookie` 头；没有就返回 null（此时不写该头）。
  /// 挑战层 Cookie 默认不外发（旧落盘罐里可能已混入，见 [isWafCookie]）；
  /// 例外：来自 WebView 会话的凭据照常出示。
  static String? cookieHeader() {
    if (_jar.isEmpty) return null;
    return _jar.entries
        .where((e) => !isWafCookie(e.key) || e.key == 'acw_sc__v2' || e.key == 'nox_jst_v1')
        .map((e) => '${e.key}=${e.value}')
        .join('; ');
  }

  /// 挑战层 Cookie：**不进罐、不外发**。
  ///
  /// 这类 Cookie 由站点的防护层下发，有效期与签发条件都不由本应用掌握。一旦收进
  /// 罐里，后续每个请求都会携带一份自己无法续期的凭据，站点侧因此无法正确判定会话
  /// 状态，表现为论坛持续不可用。这类凭据只在 WebView 内维护，应用侧不持有。
  static bool isWafCookie(String name) =>
      name.startsWith('acw') || name == 'nox_jst_v1' || name == 'cdn_sec_tc';

  /// 收下响应里的 `Set-Cookie`。Discuz 游客也会发 saltkey 等成员，照单全收
  /// （WAF 层的除外，见 [isWafCookie]）。
  static void absorbSetCookie(List<String>? setCookies) {
    if (setCookies == null || setCookies.isEmpty) return;
    for (final line in setCookies) {
      final first = line.split(';').first.trim();
      final eq = first.indexOf('=');
      if (eq <= 0) continue;
      final cookieName = first.substring(0, eq).trim();
      final value = first.substring(eq + 1).trim();
      if (cookieName.isEmpty || isWafCookie(cookieName)) continue;
      if (value.isEmpty) {
        _jar.remove(cookieName);
      } else {
        _jar[cookieName] = value;
      }
    }
  }

  /// 登录 WebView 拿到的一整串 Cookie 头（形如 `a=1; b=2`）一次性并入。
  ///
  /// [replace] 时先清空再并（登录取回用：以 WebView 里那份为准，
  /// 避免旧会话的 `_auth` 等残留键混进去）。WAF 层 Cookie 滤掉（见 [isWafCookie]）。
  static void absorbCookieHeader(String? header, {bool replace = false}) {
    if (header == null || header.trim().isEmpty) return;
    if (replace) _jar.clear();
    for (final part in header.split(';')) {
      final eq = part.indexOf('=');
      if (eq <= 0) continue;
      final cookieName = part.substring(0, eq).trim();
      final value = part.substring(eq + 1).trim();
      if (cookieName.isEmpty || value.isEmpty || isWafCookie(cookieName)) continue;
      _jar[cookieName] = value;
    }
  }

  /// 退出登录 / 重置：罐、账号视图与落盘文件一起清。
  /// 阅读侧退出（`YmAuth.logout`）连带调这里（「两份登录态，退出一起清」口径）。
  static Future<void> clear() async {
    _jar.clear();
    account.value = ForumAccount.none;
    try {
      final file = await _sessionFile();
      if (file != null && await file.exists()) await file.delete();
    } catch (_) {
      // 删不掉下次覆盖也行，不阻塞退出
    }
  }

  /// 从 WebView 会话取挑战层凭据。
  ///
  /// 这类凭据只能由浏览器引擎生成。网页壳 / 登录 WebView 完成验证后，凭据存在
  /// WebView 的 Cookie 里，同源请求可以沿用。这是它们进罐的**唯一**通道
  /// （[absorbSetCookie] / [absorbCookieHeader] 都滤掉，服务器下发的挑战层
  /// Cookie 与已验证凭据不是一回事，见 [isWafCookie]）。
  /// [header] 仅供测试注入；省略时读真 WebView。
  static Future<bool> absorbWafPassFromWebview({String? header}) async {
    try {
      final source = header ?? await YmNative.cookie('https://bbs.yamibo.com/');
      if (source.isEmpty) return false;
      var got = false;
      for (final name in const ['acw_sc__v2', 'nox_jst_v1']) {
        final m = RegExp('$name=([^;]+)').firstMatch(source);
        if (m != null) {
          _jar[name] = m.group(1)!;
          got = true;
        }
      }
      return got;
    } catch (_) {
      // 通道不可用（如测试环境）：当作借不到，调用方走 WAF 人话报错
      return false;
    }
  }

  /// 罐里有没有论坛登录态 Cookie（`_auth` 键）。落盘前仅内存判断用；
  /// 权威判定仍以页面返回的 `discuz_uid` 为准（见 [forumPageSaysGuest]）。
  static bool get hasAuthCookie => _jar.containsKey('EeqY_2132_auth');

  /// 仅测试用：把内存态复位。
  @visibleForTesting
  static void resetForTest() {
    _jar.clear();
    account.value = ForumAccount.none;
    _loaded = false;
    _file = null;
  }
}

/// 论坛登录态判定（口径，见落地方案 §4）：
/// - 页面脚本 `discuz_uid = '0'` → 游客；
/// - 页面带 `pg_logging`（被 302 到登录页的 body class）→ 游客；
/// - 两者都不是 → 视为已登录。
bool forumPageSaysGuest(String html) {
  final uid = discuzUid(html);
  return html.contains('pg_logging') || uid.isEmpty || uid == '0';
}

/// 从一页论坛 HTML 里提取账号视图（uid 以页面脚本 `discuz_uid` 为权威，
/// 昵称按页面里「指向自己 uid 空间页」的链接取，取不到留空——不编）。
ForumAccount forumAccountFromPage(String html, {required ForumAccount previous}) {
  final uid = discuzUid(html);
  if (uid.isEmpty || uid == '0') return ForumAccount.none;
  return ForumAccount(
    loggedIn: true,
    name: forumUserName(html, uid: uid) ?? previous.name,
    uid: uid,
    checkedAt: DateTime.now().millisecondsSinceEpoch,
  );
}

/// 论坛登录 / 退出（页面层只调这里的编排，不直接碰原生桥与罐）。
class ForumAuth {
  ForumAuth._();

  /// WebView 登录完成后调：从原生桥取回 bbs 域 Cookie → 写论坛罐 →
  /// 开一页论坛首页核对 `discuz_uid` → 确认已登录才落盘。
  ///
  /// 返回是否真的拿到了登录态（拿不到调用方留在网页里继续）。
  static Future<bool> pullFromWebview() async {
    final header = await YmNative.cookie('https://bbs.yamibo.com/');
    if (header.trim().isEmpty) return false;
    // 以 WebView 里那份为准整罐替换，避免旧 `_auth` 残留
    ForumSession.absorbCookieHeader(header, replace: true);
    if (!ForumSession.hasAuthCookie) return false;
    return verifyAndPersist();
  }

  /// 用当前罐请求论坛首页核对登录态，成功就更新账号视图并落盘。
  /// 罐里没有 `_auth` 时直接返回 false，不发请求。
  static Future<bool> verifyAndPersist() async {
    if (!ForumSession.hasAuthCookie) return false;
    final previous = ForumSession.account.value;
    final html = await _fetchHomeForVerify();
    if (html == null) return false;
    final acc = forumAccountFromPage(html, previous: previous);
    if (!acc.loggedIn) return false;
    ForumSession.account.value = acc;
    await ForumSession.save();
    return true;
  }

  /// 论坛退出登录（与阅读侧退出相互独立）：
  /// ① 站内注销——Discuz 标准的 `member.php?mod=logging&action=logout&formhash=`
  ///    （formhash 从论坛首页拿，登录态才有；失败不阻塞本地清理）；
  /// ② WebView 里 bbs 域 Cookie **逐条过期**——不走 `YmNative.clearCookies`，
  ///    它的兜底 removeAllCookies 会把阅读侧 www 的会话一起清掉；
  /// ③ 清论坛罐 + 落盘文件。
  static Future<bool> logout() async {
    try {
      final home = await ForumHttp.instance.request('/forum.php?mobile=2');
      final hash = formhash(home.body);
      if (hash.isNotEmpty) {
        await ForumHttp.instance.request(
          '/member.php?mod=logging&action=logout&formhash=$hash&mobile=2',
          referer: '$kForumBase/forum.php?mobile=2',
        );
      }
    } catch (_) {
      // 站内注销失败（断网 / 站点抽风）：本地退出照做，Cookie 会被清掉
    }
    await _expireWebviewBbsCookies();
    await ForumSession.clear();
    return true;
  }

  /// WebView 里 bbs 域的 Cookie 逐条过期：读一遍 → 每个名字写两条 Max-Age=0
  /// （host-only `Path=/` 一条 + `Domain=.yamibo.com` 一条，两种落法都覆盖）。
  static Future<void> _expireWebviewBbsCookies() async {
    final raw = await YmNative.cookie('$kForumBase/');
    if (raw.trim().isEmpty) return;
    for (final part in raw.split(';')) {
      final eq = part.indexOf('=');
      if (eq <= 0) continue;
      final name = part.substring(0, eq).trim();
      if (name.isEmpty) continue;
      await YmNative.setCookie('$kForumBase/', '$name=; Max-Age=0; Path=/');
      await YmNative.setCookie(
          '$kForumBase/', '$name=; Max-Age=0; Path=/; Domain=.yamibo.com');
    }
  }

  /// 核对用的小请求（forum_auth ↔ forum_http 循环 import 在 Dart 里没问题：
  /// 真正的依赖方向是 http→auth 的罐，auth→http 只是发一页请求）。
  static Future<String?> _fetchHomeForVerify() async {
    try {
      final res = await ForumHttp.instance.request('/forum.php?mobile=2');
      return res.body;
    } catch (_) {
      // 断网 / WAF：核对不了就不落盘，调用方留在网页里
      return null;
    }
  }
}

/// 页面里的 `formhash` 透出（写操作令牌，收藏 / 签到都要）。
String forumFormhashOf(String html) => formhash(html);
