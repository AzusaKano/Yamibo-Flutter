/// 论坛用户资料模型（个人资料页，`home.php?mod=space&mycenter=1&mobile=2`）。
///
/// 与 `forum_models.dart` 分开：那份是「列表 / 帖子」的页级结构，
/// 这里是一个人的资料，生命周期与缓存口径都不同（进程内、不落盘）。
library;

/// 资料表里的一行。label / value 都是**站点原文**（去标签、去实体编码），
/// 不整理、不翻译、不做繁简互转。
class ForumProfileField {
  const ForumProfileField({required this.label, required this.value});

  final String label;
  final String value;

  @override
  String toString() => 'ForumProfileField($label: $value)';
}

/// 一个人的资料页。
///
/// ⚠ **数字字段一律 `int?`**：`0` 是站点真的印了 0（新号积分就是 0），
/// 「站点没印这个数」是 `null`。这是本工程「0 = 未给」口径的**书面例外**——
/// 那套口径是给「取不到就是 0 次浏览」这类计数定的，放到资料上会把
/// 「积分 0 分」和「站点没印积分」抹成同一件事，页面上就没法判断该不该画那一格。
///
/// 字段缺失（拿不到）时：字符串给空串、数字给 null、[fields] 里干脆不出现这一行。
class ForumProfile {
  const ForumProfile({
    this.uid = '',
    this.name = '',
    this.group = '',
    this.adminGroup = '',
    this.signature = '',
    this.formhash = '',
    this.registerTime = '',
    this.lastVisit = '',
    this.totalPoints,
    this.points,
    this.partner,
    this.onlineHours,
    this.fields = const <ForumProfileField>[],
    this.isSelf = false,
  });

  /// 站点 uid（资料行里那一行；取不到时用请求时带进来的 uid）。
  final String uid;

  /// 昵称（`<h2 class="name">`）。
  final String name;

  /// 用户组原文（站点用 `<font>` 上色，解析时剥成纯文本）。
  final String group;

  /// 管理组原文。多数用户没有（资料行里印一个空 `<span>`）。
  final String adminGroup;

  /// 个人签名（纯文本，`<br>` 转成换行；本期不做富文本）。
  final String signature;

  /// 页面里的写操作令牌。**只有「我自己」的页面有**（在 `btn_exit` 的退出链接里），
  /// 他人视角没有——所以任何写操作仍然只能走网页壳。
  final String formhash;

  /// 注册时间（站点原文，如 `2023-1-1 10:00`）。
  final String registerTime;

  /// 最后访问（站点原文）。头卡上显示的就是它，资料表里不重复出现。
  final String lastVisit;

  /// 三格：总积分 / 积分 / 对象。站点把「值」印在标签**前面**。
  /// 积分原文常带「点」（`12000 点`），解析时只留数字。
  final int? totalPoints;
  final int? points;
  final int? partner;

  /// 在线时间（原文 `9358 小时`，只留数字）。
  final int? onlineHours;

  /// 其余资料行（label / value 站点原文）。
  ///
  /// 不含这三行：`用户组` / `管理组` 有各自的字段，`最后访问` 归头卡
  /// （同一件事实不在页面上出现两次）。
  final List<ForumProfileField> fields;

  /// 这是「我自己」的资料页。判据：页面有 `btn_exit`，或资料表头带「设置」。
  final bool isSelf;
}
