import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'native_bridge.dart';

/// 账号视图（对齐 uni `services/auth.js` 的 `getAccount()`）。
///
/// 只保存「站点认给我们的东西」：Cookie、昵称、UID、校验时间。**不碰账号密码。**
/// `loggedIn` 是 `/my` 真实返回的结论，不是本地自说自话的标记。
@immutable
class YmAccount {
  const YmAccount({
    this.loggedIn = false,
    this.name = '',
    this.uid = '',
    this.at = 0,
    this.checkedAt = 0,
  });

  final bool loggedIn;
  final String name;
  final String uid;

  /// 拿到会话的时间 / 最后一次向站点核对的时间（毫秒）。
  final int at;
  final int checkedAt;

  static const YmAccount none = YmAccount();

  YmAccount copyWith({
    bool? loggedIn,
    String? name,
    String? uid,
    int? at,
    int? checkedAt,
  }) {
    return YmAccount(
      loggedIn: loggedIn ?? this.loggedIn,
      name: name ?? this.name,
      uid: uid ?? this.uid,
      at: at ?? this.at,
      checkedAt: checkedAt ?? this.checkedAt,
    );
  }

  /// 账号卡上显示的名字：没昵称但确实已登录时退回「已登录」。
  String get displayName => name.isNotEmpty ? name : (loggedIn ? '已登录' : '登录百合会');

  Map<String, Object?> toJson() => <String, Object?>{
        'loggedIn': loggedIn,
        'name': name,
        'uid': uid,
        'at': at,
        'checkedAt': checkedAt,
      };

  static YmAccount fromJson(Map<String, Object?> json) {
    return YmAccount(
      loggedIn: json['loggedIn'] == true,
      name: (json['name'] as String?) ?? '',
      uid: (json['uid'] as String?) ?? '',
      at: (json['at'] as num?)?.toInt() ?? 0,
      checkedAt: (json['checkedAt'] as num?)?.toInt() ?? 0,
    );
  }

  // 值相等：`ValueNotifier` 只在值变时才通知，避免「清空到已是空的账号」白刷一次界面。
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is YmAccount &&
        other.loggedIn == loggedIn &&
        other.name == name &&
        other.uid == uid &&
        other.at == at &&
        other.checkedAt == checkedAt;
  }

  @override
  int get hashCode => Object.hash(loggedIn, name, uid, at, checkedAt);
}

/// 站点会话（Cookie）＋账号视图。
///
/// 与 uni 版 `services/session.js` 对齐：只保存**站点发的 Cookie**，不碰账号密码。
///
/// 两处与 uni 版不同的实现，源于 Flutter 侧的限制：
/// - **落盘**：`shared_preferences` / `path_provider` 新版都依赖 `jni`（要真 NDK + CMake），
///   本机 NDK 是元数据桩 ⇒ 目录走原生桥 `YmNative.filesDir()`，文件用 `dart:io` 读写。
/// - **可监听**：页面在 `build` 里直接读静态字段的话，登录成功后不会重建。
///   所以账号视图是 [ValueNotifier]，登录 / 退出 / 校验都会通知。
class YmSession {
  YmSession._();

  /// 账号视图。页面用 `ValueListenableBuilder` 或 `addListener` 订阅。
  static final ValueNotifier<YmAccount> account =
      ValueNotifier<YmAccount>(YmAccount.none);

  /// Cookie 罐：name → value。只保留 name=value，忽略属性（域/路径/过期都由站点决定）。
  static final Map<String, String> _jar = <String, String>{};

  static bool _loaded = false;

  static bool get loggedIn => account.value.loggedIn;

  static String get name => account.value.name;

  static String get uid => account.value.uid;

  static bool get loaded => _loaded;

  /// 会话文件名。放在 App 私有目录，卸载才清。
  static const String _fileName = 'ym_session.json';

  static File? _file;

  static Future<File?> _sessionFile() async {
    final cached = _file;
    if (cached != null) return cached;
    final dir = await YmNative.filesDir();
    if (dir == null || dir.isEmpty) return null;
    return _file = File('$dir${Platform.pathSeparator}$_fileName');
  }

  /// 启动时调用：把上次的 Cookie 与账号视图读回来。
  ///
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
        account.value = YmAccount.fromJson(user);
      }
    } catch (_) {
      // 坏档不影响启动：当游客，下一次登录会覆盖
    }
  }

  /// 落盘（异步，失败不影响内存态）。登录/退出/校验后由 auth 层调用。
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

  /// 发给站点的 `Cookie` 头；没有就返回 null（此时不写该头）。
  static String? cookieHeader() {
    if (_jar.isEmpty) return null;
    return _jar.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  /// 收下响应里的 `Set-Cookie`。只保留 name=value，忽略属性。
  static void absorbSetCookie(List<String>? setCookies) {
    if (setCookies == null || setCookies.isEmpty) return;
    for (final line in setCookies) {
      final first = line.split(';').first.trim();
      final eq = first.indexOf('=');
      if (eq <= 0) continue;
      final cookieName = first.substring(0, eq).trim();
      final value = first.substring(eq + 1).trim();
      if (cookieName.isEmpty) continue;
      if (value.isEmpty) {
        _jar.remove(cookieName);
      } else {
        _jar[cookieName] = value;
      }
    }
  }

  /// 登录 WebView 拿到的一整串 Cookie 头（形如 `a=1; b=2`）一次性并入。
  ///
  /// 站内换过 `PHPSESSID` 时以 WebView 里那份为准：`replace` 会先清空，
  /// 避免旧会话的残留键混进去。
  static void absorbCookieHeader(String? header, {bool replace = false}) {
    if (header == null || header.trim().isEmpty) return;
    if (replace) _jar.clear();
    for (final part in header.split(';')) {
      final eq = part.indexOf('=');
      if (eq <= 0) continue;
      final cookieName = part.substring(0, eq).trim();
      final value = part.substring(eq + 1).trim();
      if (cookieName.isEmpty || value.isEmpty) continue;
      _jar[cookieName] = value;
    }
  }

  /// 更新账号视图并落盘（登录成功 / `/my` 校验之后）。
  static Future<void> apply(YmAccount next) async {
    account.value = next;
    await save();
  }

  /// `/my` 判定为未登录：只退账号视图，**保留 Cookie**（站点刚给的那份还有用）。
  static Future<void> markLoggedOut() async {
    if (account.value.loggedIn == false && account.value.name.isEmpty) return;
    account.value = YmAccount.none;
    await save();
  }

  /// 退出登录：Cookie 与账号视图一起清。
  static Future<void> clear() async {
    _jar.clear();
    account.value = YmAccount.none;
    await save();
  }

  /// 仅测试用：把内存态复位。
  @visibleForTesting
  static void resetForTest() {
    _jar.clear();
    account.value = YmAccount.none;
    _loaded = false;
    _file = null;
  }
}
