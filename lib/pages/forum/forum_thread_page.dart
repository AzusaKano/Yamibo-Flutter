import 'dart:async' show unawaited;
import 'dart:math' show max;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent, ScrollDirection;

import '../../data/forum/forum_api.dart';
import '../../data/forum/forum_auth.dart';
import '../../data/forum/forum_http.dart' show kForumBase;
import '../../data/forum/forum_models.dart'
    show ForumPost, ForumThreadSummary, ForumTocEntry;
// 数据模型与本页 widget 同名，取页结果在此别名引用。
import '../../data/forum/forum_models.dart' as forum_models show ForumThreadPage;
import '../../data/forum/forum_track.dart';
import '../../data/forum/forum_write.dart' show favoriteThread, ForumWriteKind;
import '../../data/cache/ym_cache_store.dart' show YmCache;
import '../../data/http.dart' show YmHttpError;
import '../../data/models.dart' show YmChapterRef;
import '../../data/native_bridge.dart' show YmNative;
import '../../design/widgets/button.dart' show YmButton, YmButtonKind;
import '../../design/pressable.dart';
import '../../design/widgets/chip.dart';
import '../../design/theme.dart';
import '../../design/tokens.dart';
import '../../design/widgets/forum/forum_post_card.dart';
import '../../design/widgets/menu.dart'
    show
        YmMenuIconTrigger,
        YmMenuItemData,
        YmMenuOrigin,
        YmMenuPlacement,
        YmMenuSection,
        showYmMenu;
import 'forum_image_viewer.dart' show openForumImageViewer;
import 'forum_check_sheet.dart' show showForumCheckSheet;
import 'forum_offline_sheet.dart' show showForumOfflineSheet;
import 'forum_reader_page.dart' show ForumReaderPage;
import '../../design/widgets/lists.dart';
import '../../design/widgets/sheet.dart';
import '../../design/widgets/state_view.dart';
import '../../design/widgets/toast.dart';
import '../../design/widgets/top_bar.dart';
import '../../design/ym_route.dart';
import '../routes.dart';
import 'forum_login_page.dart' show ForumLoginPage;
import 'forum_web.dart'
    show
        forumThreadWebPath,
        openForumBodyLink,
        openForumReplyPage,
        openForumWafVerifyPage,
        openForumWeb;

/// C 帖子页：标题块 + 楼层卡 + 加载更多 + 底部回复条。
/// **不做原生回帖**：回复 / 投票 / 评分动作全部打开站内网页（已带论坛 Cookie）。
///
/// 0.1.38 起回复入口**直开回帖表单页**（不再先开浏览页让用户自己找按钮），
/// 提交成功后网页壳自动关掉、本页刷新到最新。
///
/// 0.1.22 起支持 [initialPage]（直接载到某页）+ [anchorPid]（载入后滚到那一楼），
/// 服务 findpost 内链的「精准跳楼」（findpost 302 Location 里页码是服务端算好的）。
class ForumThreadPage extends StatefulWidget {
  const ForumThreadPage({
    super.key,
    required this.tid,
    this.name = '',
    this.initialPage = 1,
    this.anchorPid = '',
    this.resumeToast = false,
    this.restoreProgress = true,
    this.startFresh = false,
  });

  final String tid;

  /// 进来前知道的板块名（列表行没有板块信息，一般空着，靠帖子页自己解析）。
  final String name;

  /// 首次载入的页码（findpost 跳楼 / 追帖恢复用；默认 1）。
  final int initialPage;

  /// 要定位到的楼层 pid（本页里必须有这楼；没有就停在页首，不编位置）。
  final String anchorPid;

  /// 从追帖 / 历史恢复进度进入：定位成功时弹一次「已回到上次阅读」。
  /// findpost 跳楼等其它入口不传（默认 false），不弹这条提示。
  /// [restoreProgress] 入口默认恢复时也弹（判据见 state 的 [_resumeFrom]）。
  final bool resumeToast;

  /// 普通入口默认恢复上次读到的页码与楼层（首页 / 板块 / 搜索 / 正文帖子链接）。
  /// 显式入口（findpost / 追帖 / 历史）传了页码或锚点，本来就优先；这里只是
  /// 给 findpost 这类「不能恢复」的入口一个关掉默认恢复的开关。
  final bool restoreProgress;

  /// 「从头看」：显式从 [initialPage] 开始并**不读**已存进度，首载照常写基线
  /// ⇒ 历史被重置到这一页的第一楼。
  final bool startFresh;

  @override
  State<ForumThreadPage> createState() => _ForumThreadPageState();
}

/// 页码盘里「这一页已离线」的小圆点（5px，跟着胶囊的前景色走）。
class _OfflineDot extends StatelessWidget {
  const _OfflineDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 5,
      height: 5,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// 圆点的说明行（有已存页才出现）。
class _OfflineDotHint extends StatelessWidget {
  const _OfflineDotHint({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _OfflineDot(color: color),
        const SizedBox(width: 5),
        Text(
          '带点的页已离线保存',
          style: TextStyle(fontSize: YmFont.micro11, color: color),
        ),
      ],
    );
  }
}

class _ForumThreadPageState extends State<ForumThreadPage> {
  final List<ForumPost> _posts = <ForumPost>[];
  final ScrollController _scroll = ScrollController();
  String _title = '';
  String _tag = '';
  String _boardName = '';
  int _views = 0;
  int _replies = 0;
  int _page = 0;

  /// 本帖板块号（回帖表单 URL 里的 `fid`，0.1.38 从帖页 HTML 的回帖链接解析）。
  /// 拿不到是空串——表单页不带 fid 也能开，不猜板块号。
  String _fid = '';

  /// 已载入的页码范围两端：触顶补上一页 / 触底续下一页都从这里推。
  int _lowestPage = 0;
  int _highestPage = 0;
  int _totalPages = 0;
  bool _loading = false;
  String? _error;

  /// 错误码（WAF → 错误态出「去网页过一次验证」；SITE_MESSAGE → 站方消息兜底态）。
  String? _errorCode;

  /// 点评展开态（默认折叠，只铺 1–2 条）。
  final Set<String> _expandedComments = <String>{};

  /// 每一楼所属的站点页码（连读多页后「回复按楼定位」的依据）。
  final Map<String, int> _postPage = <String, int>{};

  /// 每一楼一个 key：滚楼定位 + 「正在读第几页」判定都用它。
  final Map<String, GlobalKey> _postKeys = <String, GlobalKey>{};

  /// 列表的 key（视口参照物，「正在读第几页」按楼层相对视口顶的位置判定）。
  final GlobalKey _listKey = GlobalKey();

  /// 当前**正在读**的页码（视口顶压在哪个楼上就算哪页；右上角按钮是
  /// 「已加载到第几页」，两个信息不重复——0.1.22 反馈）。
  int _readingPage = 0;

  GlobalKey _keyFor(String pid) => _postKeys.putIfAbsent(pid, GlobalKey.new);

  /// 收藏（本页会话态：成功后就地变「已收藏」；重启后站点为准，本地不编）。
  bool _faving = false;
  bool _faved = false;

  /// 追帖（本地能力）：按钮态从 store 读；游客也能用，不写站点。
  bool _tracked = false;

  /// 首楼目录：`null` = 本次页面会话还没拿到（例如从第 5 页恢复进来的）。
  /// 只在内存里活，不持久化；已知且不足 3 条时阅读入口收起。
  List<ForumTocEntry>? _toc;

  /// 阅读入口懒拉目录的进行中标记（防连点叠请求）。
  bool _tocLoading = false;

  /// 进入时已存的进度（恢复入口读）：首载基线不能覆盖它，
  /// 是否弹「已回到上次阅读」也按它判断「不是第 1 页第 1 楼」。
  /// 判据统一走它，不再看 [ForumThreadPage.resumeToast]——普通入口默认恢复也要弹。
  ForumTrackRecord? _resumeFrom;

  /// 本次进入实际要载的页码 / 要定位的楼层：initState 里一次定死。
  /// 不能直接读 `widget.anchorPid`——普通入口的定位目标来自 store（默认恢复）。
  int _initialPage = 1;
  String _anchorPid = '';

  /// 最近一次记下的视口顶楼进度（dispose 时 renderObject 可能已 detach，
  /// 靠这份缓存 immediate 直写，不在 dispose 里 setState）。
  ({String pid, int floor, int page})? _lastProgress;

  /// 右上角菜单触发器（算显式落点用）+ 展开态。
  final GlobalKey _menuKey = GlobalKey();
  bool _menuOpen = false;

  /// 首次载入是否完成（[ForumThreadPage.initialPage] 可以不是 1，
  /// 标题 / 楼层列表的初始化按「第一次成功载入」判定，不按页码 1）。
  bool _firstLoaded = false;

  /// 哪几页是**从本机离线副本**读出来的（第三期）。
  ///
  /// 按页记，不是一个整帖开关：部分下载时页面会混着"副本页 / 在线页"，
  /// 副行只按**当前正在读的那一页**标「离线」，翻到在线页就自动消失
  /// （2026-11-24 真机反馈：从副本页跳到没存的页仍然显示离线）。
  final Set<int> _cachedPages = <int>{};

  /// 已经静默探过一次「站点现在共几页」（每次进页面只探一次）。
  bool _probedTotal = false;

  /// 滚楼只做一次（锚点楼在首次载入的页里；后续翻页不再找）。
  bool _anchorDone = false;

  /// 用户已经手动滚过（拖动列表）就不再自动拽位置（滚楼与校准都让位）。
  bool _userInteracted = false;

  /// 顶部补页的「量尺」：补页内容先挂在列表最底部量高度，量完在帧间隙里
  /// 「偏移 +H + 搬家到顶部」同帧完成（详见 _finishPrepend）。
  List<ForumPost>? _pendingPrepend;
  final GlobalKey _prependedKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    final store = ForumTrackStore.instance;
    _tracked = store.isTracked(widget.tid);
    _resolveEntry(store);
    _load(_initialPage);
  }

  /// 定本次进入的页码与定位楼层（四档，顺序即优先级）：
  ///
  /// 1. 「从头看」：用传入页码（通常 1），**不读** store ⇒ 首载照常写基线，
  ///    历史被重置到这一页第一楼；
  /// 2. 显式入口（findpost 带 anchorPid / 追帖历史带 initialPage > 1）：用传入值，
  ///    不覆盖也不靠 store；[ForumThreadPage.resumeToast] 入口照原逻辑抓记录用于提示；
  /// 3. 普通入口默认恢复：store 里有 lastPage > 0 就回到保存的页 / 楼，
  ///    记 [_resumeFrom]，首载跳过基线（否则第 7 页 128 楼会被第 1 页第一楼盖掉）；
  /// 4. 都没有：第 1 页，正常写基线。
  void _resolveEntry(ForumTrackStore store) {
    final saved = store.recordOf(widget.tid);
    _initialPage = widget.initialPage;
    if (widget.startFresh) {
      _anchorPid = widget.anchorPid;
      return;
    }
    if (widget.anchorPid.isNotEmpty || widget.initialPage > 1) {
      _anchorPid = widget.anchorPid;
      if (widget.resumeToast) _resumeFrom = saved;
      return;
    }
    if (widget.restoreProgress && saved != null && saved.lastPage > 0) {
      _initialPage = saved.lastPage;
      // 保存的楼层可能已被删：那时只开页，不编位置。
      _anchorPid = saved.lastPid;
      _resumeFrom = saved;
      return;
    }
    _anchorPid = '';
  }

  @override
  void dispose() {
    // 退出即补记一次进度：此刻之后没有下次写盘机会，immediate 直写。
    //
    // 但这笔记录**不能在本帧内通知**（第九期）：dispose 发生在路由 pop 收尾那一帧的
    // finalizeTree 里，此时同步 notifyListeners() 会让正处于前台的书架（
    // shelf_page.dart 的 AnimatedBuilder 监听 ForumTrackStore）当场标脏重建；
    // 真机上这一帧之后引擎会停止出帧数秒（点击照常处理、状态照常改，但画面不动、
    // 胶囊与底栏看起来点不动），直到下一次触摸才补画。挪到本帧收尾之后再做，
    // 重建落在普通帧里，现象消失。
    final last = _lastProgress;
    if (last != null && widget.tid.isNotEmpty) {
      final String tid = widget.tid;
      final String pid = last.pid;
      final int floor = last.floor;
      final int page = last.page;
      final int totalPages = _totalPages;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ForumTrackStore.instance.recordRead(
          tid: tid,
          pid: pid,
          floor: floor,
          page: page,
          totalPages: totalPages,
          immediate: true,
        );
      });
      // dispose 可能发生在帧外（无后续帧），补一次调度保证回调一定跑到
      WidgetsBinding.instance.ensureVisualUpdate();
    }
    _scroll.dispose();
    super.dispose();
  }

  /// 首载成功后写元数据 + 一条进度基线（当前页第一个楼）。
  ///
  /// 恢复入口跳过基线：保存的楼层还没定位成功，不能被当前页第一楼覆盖。
  void _recordBaseline(forum_models.ForumThreadPage data) {
    final store = ForumTrackStore.instance;
    final first = data.posts.isNotEmpty ? data.posts.first : null;
    store.updateMeta(
      tid: widget.tid,
      title: data.title,
      boardName: data.boardName.isNotEmpty ? data.boardName : widget.name,
      // 首楼作者（floor == 1）;拿不到就留空，不编。
      author: data.posts.where((p) => p.floor == 1).firstOrNull?.author ?? '',
      replies: data.replies,
    );
    if (_resumeFrom != null || first == null) return;
    store.recordRead(
      tid: widget.tid,
      pid: first.pid,
      floor: first.floor,
      page: data.page,
      totalPages: data.totalPages,
    );
    _lastProgress = (pid: first.pid, floor: first.floor, page: data.page);
  }

  /// 载入一页。普通调用 = 追加到列表尾（「加载更多」/ 触底续载）；
  /// [prepend] = 顶部补上一页（触顶续载），载入后把滚动位置钉回原来的楼上。
  /// [forceRefresh] = 菜单「刷新」：跳过本机副本，强制走网络（刷新不写盘，
  /// 只有下载任务写盘 —— 缓存第一期的硬口径）。
  Future<void> _load(int next,
      {bool prepend = false,
      bool settleProgress = false,
      bool forceRefresh = false,
      bool updateCache = false}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      _errorCode = null;
    });
    try {
      final data = await fetchForumThread(
        widget.tid,
        page: next,
        forceRefresh: forceRefresh,
        updateCache: updateCache,
      );
      if (!mounted) return;
      final isFirst = !_firstLoaded;
      if (isFirst) {
        _recordBaseline(data);
      } else if (settleProgress && data.posts.isNotEmpty) {
        // 翻页：列表清空重载后视口回到新页第一楼，主动补记一次（滚动不起来就没有
        // _updateReadingPage 的机会）。恢复入口不靠这条路径。
        final p = data.posts.first;
        _lastProgress = (pid: p.pid, floor: p.floor, page: data.page);
        ForumTrackStore.instance.recordRead(
          tid: widget.tid,
          pid: p.pid,
          floor: p.floor,
          page: data.page,
          totalPages: data.totalPages,
        );
      }
      setState(() {
        // 板块号每次拿到就更新（刷新 / 翻页都会重载，早先的不要盖掉新的）
        if (data.fid.isNotEmpty) _fid = data.fid;
        if (isFirst) {
          _posts.clear();
          _title = data.title;
          _tag = data.tag;
          _views = data.views;
          _replies = data.replies;
          _boardName = data.boardName.isNotEmpty ? data.boardName : widget.name;
          _firstLoaded = true;
        }
        // 顶栏「离线」按**页**记：这一页是副本回出来的才标（第三期）。
        if (data.fromCache) {
          _cachedPages.add(data.page);
        } else {
          _cachedPages.remove(data.page);
        }
        if (prepend) {
          // 补页不直接进主列表：先挂在列表最底部当「量尺」（底部追加不闪），
          // 量出高度后在帧间隙里「偏移 +H + 搬家到顶部」同帧完成——
          // 直接插到顶部会让「没校准的那一帧」上屏，真机就是一下闪烁。
          _pendingPrepend = data.posts;
          for (final p in data.posts) {
            _postPage[p.pid] = data.page;
          }
        } else {
          // 站点对「越过最后一页」的请求会**原样返回末页内容**（0.1.23 实测
          // 533721：单页帖请求 page=2 → 200 + 同一批楼层）——重复 pid 进列表
          // 会撞 GlobalKey（视图卡死），全重复就当翻到底，总页数钳回真实末页。
          final fresh =
              data.posts.where((p) => !_postPage.containsKey(p.pid)).toList();
          final clamped = data.posts.isNotEmpty && fresh.isEmpty;
          if (!clamped) {
            _posts.addAll(fresh);
            if (fresh.isNotEmpty) {
              _page = data.page;
              _highestPage = data.page;
            }
          } else {
            _page = max(1, next - 1);
            _highestPage = _page;
          }
          for (final p in fresh) {
            _postPage[p.pid] = data.page;
          }
        }
        _totalPages = data.totalPages;
        // 目录只在第 1 页（首楼）里；补页补到 1 也顺手收下。
        if (data.page == 1) _toc = data.toc;
        if (prepend) {
          _lowestPage = data.page;
        } else {
          _highestPage = data.page;
        }
        if (_lowestPage == 0) _lowestPage = data.page;
        if (_highestPage == 0) _highestPage = data.page;
        if (_readingPage == 0) _readingPage = data.page;
        if (next > 1 && data.posts.isEmpty) _totalPages = data.page;
      });
      if (prepend && data.posts.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _finishPrepend();
        });
      }
      // 首载读到的是离线副本 ⇒ 顺手静默探一次站点当前页数（失败无事发生）
      if (isFirst && data.fromCache) unawaited(_probeTotal());
      if (!_anchorDone &&
          _anchorPid.isNotEmpty &&
          _posts.any((p) => p.pid == _anchorPid)) {
        _anchorDone = true;
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          final ok = await _scrollToAnchor();
          // 定位成功才提示；保存位置就是第 1 页第 1 楼时不打扰。
          // 判据是「这次进来有已存进度」（普通入口默认恢复也算），不是入口类型。
          if (!ok || !mounted) return;
          final saved = _resumeFrom;
          if (saved == null) return;
          if (saved.lastPage <= 1 && saved.lastFloor <= 1) return;
          showYmToast(context, '已回到上次阅读');
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is YmHttpError ? e.message : '加载失败';
        _errorCode = e is YmHttpError ? e.code : null;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// WAF 错误态唯一按钮「去验证」（借证与自动关页原理见
  /// forum_web.openForumWafVerifyPage）：打开网页壳拿新通行证自动关页，
  /// 返回后自动重试。
  Future<void> _openWafVerify() async {
    await openForumWafVerifyPage(context);
    if (mounted) _load(1);
  }

  bool get _hasMore =>
      _highestPage > 0 && (_totalPages == 0 || _highestPage < _totalPages);

  /// 上面还有没有更早的页（触顶续载的条件）。
  bool get _hasPrev => _lowestPage > 1;

  /// 全帖正文图（按楼层顺序收平，H 查看器「同帖多图左右连看」的序列）。
  List<String> get _allImages => <String>[for (final p in _posts) ...p.images];

  /// 点图进查看器：定位到被点那张（H 屏验收：带 Referer 才加载，YmForumImage 出口）。
  void _openImage(String url) {
    final images = _allImages;
    final idx = images.indexOf(url);
    openForumImageViewer(context, images, initial: idx < 0 ? 0 : idx);
  }

  /// 楼层「回复」出口（0.1.38）：直接开**回帖表单页**并带上本楼 pid（`reppost`）。
  ///
  /// 旧实现是「开这一楼所在的浏览页 + 带楼层锚点」，用户还得在网页里自己点
  /// 「发表回复」——第二步正好撞上写操作被截回原生的 bug（0.1.37 实测），
  /// 流程死在那里。现在一步到位：落在表单页就能打字。
  /// 页码按「本楼所在的站点页」传，与连读多页后回复旧页楼层的口径一致。
  void _openWeb(ForumPost post) {
    _openReplyForm(pid: post.pid, page: _postPage[post.pid] ?? _page);
  }

  /// 底栏「回复这个话题」：主题级回复（**不带** `reppost`，不用挑楼层），
  /// 页码跟「正在读的页」（连读多页时按用户眼前这页回）。
  void _openTopicWeb() =>
      _openReplyForm(page: _readingPage > 0 ? _readingPage : _page);

  /// 开回帖表单页。提交成功后由 [openForumReplyPage] 关掉网页壳并回调这里刷新。
  void _openReplyForm({String? pid, int page = 1}) {
    unawaited(openForumReplyPage(
      context,
      tid: widget.tid,
      fid: _fid,
      pid: pid,
      page: page <= 0 ? 1 : page,
      title: _title.isEmpty ? '百合会论坛' : _title,
      onSubmitted: _reloadAfterReply,
    ));
  }

  /// 回帖提交成功后的收尾（0.1.38）：网页壳已经关掉，这里把原帖刷到**最新**。
  ///
  /// 为什么刷「末页」而不是「当前正在读的页」：新楼层永远落在整帖最后一页的末尾。
  /// 用户停在第 1 页回帖时，刷第 1 页根本看不到自己刚发的那条。
  /// 服务端 302 如果带了楼层 pid（未实测到），且刷新后这一页里真有这楼，就滚过去；
  /// 拿不到 pid 或找不到楼，就落到末页底部（= 最新那一条）。
  Future<void> _reloadAfterReply(String newPid) async {
    if (!mounted) return;
    // 首载 / 上一次加载还在跑：等它落地再刷（_load 是单车道，抢进去会被直接丢掉）
    for (var i = 0; i < 20 && _loading && mounted; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!mounted) return;
    final page = _totalPages > 0 ? _totalPages : max(1, _highestPage);
    setState(() {
      _posts.clear();
      _postPage.clear();
      _postKeys.clear();
      _pendingPrepend = null;
      _page = 0;
      _lowestPage = 0;
      _highestPage = 0;
      _readingPage = 0;
      // 元数据与基线都有了，重载不再写基线（否则会把刚刷到的位置盖回页首）
      _firstLoaded = true;
      // 进场锚点早用过了，重载不该再抓它（和刷新同一口径）
      _anchorDone = true;
    });
    await _load(page);
    if (!mounted) return;
    // 自己这条回复可能把末页撑成新的一页：站点总页数变多了就补载一页
    if (newPid.isNotEmpty &&
        !_posts.any((p) => p.pid == newPid) &&
        _totalPages > page &&
        _hasMore) {
      await _load(_highestPage + 1);
      if (!mounted) return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (newPid.isNotEmpty && _posts.any((p) => p.pid == newPid)) {
        unawaited(_scrollToAnchor(pid: newPid, force: true));
      } else if (_scroll.hasClients) {
        // 落到最新：末页底部（自己那条一定在这一屏里）
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  /// 首楼投票块的出口（0.1.38）：开**帖页网页**（能看到选项、能在网页里投票），
  /// 与回复出口彻底分开——回复入口改成直开表单页后，投票若还挂在回复上
  /// 就会误开成回帖表单。投票提交本身在网页里完成（`action=votepoll` 已放行）。
  void _openPollWeb(ForumPost post) {
    unawaited(openForumWeb(
      context,
      path: forumThreadWebPath(
        widget.tid,
        page: _postPage[post.pid] ?? 1,
        anchorPid: post.pid,
      ),
      title: _title.isEmpty ? '百合会论坛' : _title,
    ));
  }

  /// 视口顶压在哪块楼上：(pid, floor, 相对视口顶的 dy)。
  /// 楼序遍历，最后一块 dy<=0（顶出视口顶）的楼说了算；一块都没越过顶
  /// （视口还在标题块）就取第一块铺出来的。列表懒铺，只看已铺出来的楼。
  ({String pid, int floor, double dy})? _topPostSnapshot() {
    final viewport = _listKey.currentContext?.findRenderObject();
    if (viewport is! RenderBox || !viewport.attached || _posts.isEmpty) {
      return null;
    }
    ({String pid, int floor, double dy})? top;
    for (final post in _posts) {
      final box = _postKeys[post.pid]?.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached) continue;
      final dy = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
      if (dy <= 0) {
        top = (pid: post.pid, floor: post.floor, dy: dy);
      } else {
        top ??= (pid: post.pid, floor: post.floor, dy: dy);
        break;
      }
    }
    return top;
  }

  /// 「正在读的页」跟随视口（右上角按钮的页码口径），同时记进度到 store。
  ///
  /// store 内部对写盘 / 通知都做了节流，这里可以跟滚动安全调用；只记到楼层，
  /// 不记楼内像素偏移。进度对所有打开过的帖子记录，不需要先追帖。
  void _updateReadingPage() {
    if (_pendingPrepend != null) return; // 量尺/搬家进行中，视口语义未定
    final top = _topPostSnapshot();
    if (top == null) return;
    final page = _postPage[top.pid];
    if (page == null) return;
    final last = (pid: top.pid, floor: top.floor, page: page);
    _lastProgress = last;
    ForumTrackStore.instance.recordRead(
      tid: widget.tid,
      pid: last.pid,
      floor: last.floor,
      page: last.page,
      totalPages: _totalPages,
      // 恢复入口首帧还没定位，别用页顶把保存进度提前覆盖掉。
      immediate: false,
    );
    if (page != _readingPage) setState(() => _readingPage = page);
  }

  /// 补页收尾（在量尺那一帧的帧尾跑）：
  ///
  /// 1. 量出挂在列表底部的补页内容高度 H；
  /// 2. **帧间隙里**先把滚动偏移 +H（此时内容还是旧的，没人看见），
  ///    再 setState 把补页内容搬到列表顶部——下一帧渲染时偏移和内容
  ///    同时就位，画面没有任何中间态（post-frame 里才校准 = 晚一帧，
  ///    真机就是一下闪烁，实测踩过；deferFirstFrame 只扣首帧，没用）。
  ///
  /// 量不到高度（极端：量尺没被铺出来）就放弃校准直接搬家——闪一下总比丢内容强。
  void _finishPrepend() {
    final pending = _pendingPrepend;
    if (pending == null || !mounted) return;
    final box = _prependedKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !_scroll.hasClients) {
      Future<void>.delayed(const Duration(milliseconds: 32), () {
        if (mounted) _finishPrepend();
      });
      return;
    }
    final h =
        _scroll.position.axis == Axis.vertical ? box.size.height : box.size.width;
    _scroll.jumpTo(_scroll.offset + h);
    setState(() {
      _posts.insertAll(0, pending);
      _pendingPrepend = null;
    });
  }

  /// 滚到锚点楼（[ForumThreadPage.anchorPid]）。
  ///
  /// ListView 是懒铺的：目标楼还没铺出来时拿不到 BuildContext，
  /// 就往前跳一屏逼它建出来，下一帧再试。
  /// ⚠ 没铺完的列表 maxScrollExtent 是**估算值**、随铺随长，而且**不保证单调**——
  /// 真机两轮实证（0.1.22）：跳 18 页的长文帖，按估算底滚到中途就停了（346 楼），
  /// 加了「范围不增长就放弃」后又停在 358 楼底（后头几楼比估算矮，范围没动）。
  /// 所以**任何「不动就放弃」的条件都不成立**：目标楼进不来只有两种可能——
  /// 还没铺到（继续跳）、楼根本不在本页（开页前已确认在本页才进这里）。
  /// 循环上限 4 秒兜底。定位完成后再补一次校准：楼里图片加载完会把上面
  /// 楼层撑高，位置会被顶跑；用户已经自己滚就让位。
  ///
  /// alignment 固定 0：长文楼层可以比屏幕还高，alignment > 0 会把楼的开头
  /// 滚出屏幕顶（reveal 公式按「目标比视口矮」推导，超高目标会滚进去一截）。
  /// 返回是否真的定位到了锚点楼（供恢复 toast 用；楼不在本页时循环耗尽返回 false）。
  ///
  /// [pid] 不传 = 本次进入的定位楼（[_anchorPid]，见 [_resolveEntry]）；
  /// 刷新时传刷新前视口顶楼，复用同一套滚楼逻辑（不另写第二套）。
  ///
  /// [force] 刷新路径专用：跳过「用户已经自己滚过就让位」的两处判断——刷新是
  /// 用户主动要求「把这一页重新载入并回到刚才看的楼」，不是自动拽位置。
  /// 普通恢复入口不传，仍尊重用户已经自己滚过的情况。
  Future<bool> _scrollToAnchor({String? pid, bool force = false}) async {
    final target = pid ?? _anchorPid;
    if (target.isEmpty) return false;
    // 目标就是当前列表第一条：不能 ensureVisible(alignment: 0)——那会把帖子标题块
    // 顶出视口。列表留在页首，标题先看到、那一楼紧随其后，仍算定位成功。
    // ⚠ 判据必须是「当前列表第一条」（不是「该页第一条」）：列表前面补过更早页时，
    // 目标可能已不是第一条，那时按滚楼逻辑走。
    final first = _posts.isNotEmpty ? _posts.first : null;
    if (first != null && first.pid == target) {
      // 顺手记下进度，免得 dispose 把页首楼写回覆盖掉它。
      _lastProgress = (
        pid: first.pid,
        floor: first.floor,
        page: _postPage[first.pid] ?? _page,
      );
      if (_scroll.hasClients) _scroll.jumpTo(0);
      return true;
    }
    for (var i = 0; i < 240 && mounted; i++) {
      if (!force && _userInteracted) return false; // 用户已经自己滚上了：让位
      final ctx = _postKeys[target]?.currentContext;
      if (ctx != null) {
        if (!ctx.mounted) return false; // 上一帧 await 期间被收掉了：放弃
        await Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 220),
          alignment: 0,
        );
        // 图片加载 / 字体沉降后再校准一次（几百毫秒内的偏移足够修回）；
        // 用户已经开始自己滚就不拽了（刷新路径除外）
        await Future<void>.delayed(const Duration(milliseconds: 350));
        if (!mounted || (!force && _userInteracted)) return true;
        final ctx2 = _postKeys[target]?.currentContext;
        if (ctx2 != null && ctx2.mounted) {
          await Scrollable.ensureVisible(
            ctx2,
            duration: const Duration(milliseconds: 160),
            alignment: 0,
          );
        }
        return true;
      }
      if (_scroll.hasClients) {
        final max = _scroll.position.maxScrollExtent;
        _scroll.jumpTo(
          (_scroll.offset + _scroll.position.viewportDimension * 0.8)
              .clamp(0.0, max),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    return false;
  }

  /// 正文链接统一出口（楼层卡 onOpenLink 回调落点）：
  /// findpost → 精准跳楼；帖子 / 板块 → 原生页；其余 → 网页壳（外站在内）。
  void _openLink(String href) => openForumBodyLink(context, href);

  /// 当前正在读的页（右上角菜单的刷新 / 浏览器打开都按这个，不是已加载到的末页）。
  int get _currentPage => _readingPage > 0 ? _readingPage : _page;

  /// 已离线保存的页数（菜单项副文案用；同步读索引，点开菜单时算一次就够）。
  int get _storedPages => YmCache.instance
      .peekOfParent('forum', widget.tid)
      .where((e) => e.state.isDone)
      .length;

  /// 静默探一次「站点现在共几页」（2026-11-25）：只在本次进入读到副本时才探。
  ///
  /// 解决两件事：① 弹层里的**可下载名单**不再停留在"存下来那天"的页数；
  /// ② 末尾那行与页码盘跟着放开 —— 不然已存到第 5 页、站点已有 6 页时，
  /// 第 5 页底下会永远写「已是最后一页」，翻不过去。
  /// 失败**无事发生**（保持副本里的页数，不影响阅读）；**只增不减**。
  Future<void> _probeTotal() async {
    if (_probedTotal) return;
    _probedTotal = true;
    try {
      final total = await probeForumThreadTotal(widget.tid);
      if (!mounted || total <= _totalPages) return;
      setState(() => _totalPages = total);
    } catch (_) {
      // 断网 / 站点抖动：沿用副本里的页数，不提示、不标错
    }
  }

  /// 菜单项文案：没存过就是「离线保存」，存过带上页数（口径见缓存第一期 §三之二）。
  String get _offlineLabel =>
      _storedPages > 0 ? '离线保存 · 已存 $_storedPages 页' : '离线保存';

  /// 打开「离线保存」弹层。总页数 / 回复数用本页解析到的值，
  /// 拿不到（0）时由弹层退回索引里记着的数。
  Future<void> _openOfflineSheet() async {
    await showForumOfflineSheet(
      context,
      tid: widget.tid,
      title: _title,
      totalPages: _totalPages,
      replies: _replies,
    );
  }

  /// 打开「检查更新」弹层（2026-11-25：从离线弹层提到菜单）：
  /// 弹层里先看上次的核对情况，再由用户按「开始检查」真跑（逐页核对是重动作）。
  Future<void> _openCheckSheet() async {
    if (_storedPages == 0) {
      showYmToast(context, '还没有离线保存的页');
      return;
    }
    await showForumCheckSheet(
      context,
      tid: widget.tid,
      title: _title,
    );
  }

  /// 右上角菜单：位置显式从触发器 RenderBox 算出（资产包菜单不做自动翻转 / 测量）。
  Future<void> _openMenu() async {
    if (_menuOpen || !mounted) return;
    setState(() => _menuOpen = true);
    final box = _menuKey.currentContext?.findRenderObject();
    final screen = MediaQuery.sizeOf(context);
    double? top;
    double? right;
    if (box is RenderBox && box.attached) {
      final pos = box.localToGlobal(Offset.zero);
      // 贴在触发器正下方、右缘对齐；origin=topRight 从右上角展开。
      top = pos.dy + box.size.height + 4;
      right = screen.width - pos.dx - box.size.width;
    }
    await showYmMenu(
      context,
      placement: YmMenuPlacement(
        top: top ?? screen.height * 0.12,
        right: right ?? 14,
        origin: YmMenuOrigin.topRight,
      ),
      sections: [
        YmMenuSection(
          items: [
            YmMenuItemData(label: '刷新', onTap: _refreshCurrentPage),
            YmMenuItemData(label: '检查更新', onTap: _openCheckSheet),
            YmMenuItemData(label: _offlineLabel, onTap: _openOfflineSheet),
            YmMenuItemData(label: '在浏览器打开', onTap: _openInBrowser),
          ],
        ),
      ],
      semanticLabel: '帖子操作',
    );
    if (mounted) setState(() => _menuOpen = false);
  }

  /// 刷新：只重取当前正在读的这一页，不重拉已加载的其他页 / 全帖。
  /// 加载中（含首载）忽略，不叠请求。**强制走网络**（跳过本机离线副本），
  /// 但刷新本身不写盘 —— 只有「离线保存」才写。
  Future<void> _refreshCurrentPage() async {
    if (_loading) return;
    final page = _currentPage;
    if (page <= 0) return;
    final topPid = _topPostSnapshot()?.pid ?? '';
    setState(() {
      _posts.clear();
      _postPage.clear();
      _postKeys.clear();
      _pendingPrepend = null;
      _page = 0;
      _lowestPage = 0;
      _highestPage = 0;
      _readingPage = 0;
      _firstLoaded = true; // 元数据已有，重载不重复写基线
      // 进场锚点（含默认恢复的保存楼）此时已经用过一次，别让重载再抓它：
      // 刷新只回「刷新前的视口顶楼」，两个目标同时拽会互相打架。
      _anchorDone = true;
    });
    await _load(page, forceRefresh: true, updateCache: true);
    // 尽量滚回刷新前的楼；找不到就在页首（_scrollToAnchor 耗尽返回 false）。
    // force：刷新是用户主动要求的，别被「用户已滚过」的让位判断拦下。
    if (topPid.isNotEmpty && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToAnchor(pid: topPid, force: true);
      });
    }
  }

  /// 在浏览器打开：URL 带当前页 + 视口顶楼锚点；外部浏览器无登录态是预期结果。
  Future<void> _openInBrowser() async {
    final topPid = _topPostSnapshot()?.pid;
    final path = forumThreadWebPath(
      widget.tid,
      page: _currentPage > 0 ? _currentPage : 1,
      anchorPid: topPid,
    );
    final ok = await YmNative.openUrl('$kForumBase$path');
    if (!ok && mounted) showYmToast(context, '没能打开浏览器，请稍后再试');
  }

  /// 顶栏「1 / N 页」页码盘：跳到任意页（草稿 C 屏口径）。
  ///
  /// 已离线保存的页带一枚小圆点（2026-11-25 用户拍板）：部分下载时页面会混着
  /// 副本页与在线页，跳页前就该看得出哪几页断网也能读。
  Future<void> _pickPage() async {
    if (_totalPages <= 0) return;
    final stored = <int>{
      for (final e in YmCache.instance
          .peekOfParent('forum', widget.tid)
          .where((e) => e.state.isDone && e.order > 0))
        e.order,
    };
    final picked = await showYmSheet<int>(
      context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            14,
            14,
            14,
            14 + MediaQuery.paddingOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '跳到第几页',
                style: TextStyle(
                  fontSize: YmFont.strong16,
                  fontWeight: FontWeight.w700,
                  color: YmScope.of(context).colors.text,
                ),
              ),
              if (stored.isNotEmpty) ...<Widget>[
                const SizedBox(height: 6),
                _OfflineDotHint(color: YmScope.of(context).colors.text3),
              ],
              const SizedBox(height: 10),
              Flexible(
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      // 页码胶囊复用 YmChip（compact 34）。自绘 Container(alignment:)
                      // 在 Wrap 的有界约束下会撑满整行（真机翻过车：页码全宽堆叠）
                      for (var i = 1; i <= _totalPages; i++)
                        YmChip(
                          style: YmChipStyle.pill,
                          pressKind: YmPressKind.solid,
                          label: '$i',
                          // 高亮 = 正在读的页（不是已加载到的页）
                          active: i == (_readingPage > 0 ? _readingPage : _page),
                          compact: true,
                          trailing: stored.contains(i)
                              ? _OfflineDot(
                                  color: i ==
                                          (_readingPage > 0
                                              ? _readingPage
                                              : _page)
                                      ? Colors.white
                                      : YmScope.of(context).colors.brand,
                                )
                              : null,
                          onTap: () => Navigator.of(context).pop(i),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked != null && picked != _page && mounted) {
      // 全新载入：列表与载入范围全部清零（重新从 picked 这页起读）
      setState(() {
        _posts.clear();
        _postPage.clear();
        _postKeys.clear();
        _pendingPrepend = null;
        _page = 0;
        _lowestPage = 0;
        _highestPage = 0;
        _readingPage = 0;
      });
      _load(picked, settleProgress: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return Scaffold(
      body: Column(
        children: [
          YmTopBar(
            leading: const YmBackButton(),
            title: _boardName.isEmpty ? '帖子' : _boardName,
            // 页码信息只放右上角按钮（正在读的页）；副标题不重复
            // 副行只表达「当前读的这一页来自副本」：部分下载时会混着在线页，
            // 翻到在线页就不该还挂着「离线」（2026-11-24 真机反馈）
            subtitle: _page == 0 && _loading
                ? '正在加载…'
                : (_cachedPages.contains(_currentPage) ? '离线' : null),
            // 页码胶囊 + 菜单件横排；单页帖没有页码钮时菜单仍在。
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_totalPages > 1) ...[
                  YmPressable(
                    kind: YmPressKind.neutral,
                    baseColor: c.card,
                    radius: BorderRadius.circular(YmRadius.pill),
                    onTap: _pickPage,
                    child: Container(
                      // 42 定宽次按钮档（草稿 28 触控 <40 红线，拆件表 C-07）
                      height: 42,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(YmRadius.pill),
                        border: Border.all(color: c.border),
                      ),
                      child: Text(
                        // 显示「正在读的页 / 总页数」（跟随视口；0.1.22 拍板：
                        // 外观不变，只把数字从已加载页换成阅读页）
                        '${_readingPage > 0 ? _readingPage : _page} / $_totalPages 页',
                        style: TextStyle(
                          fontSize: YmFont.small12,
                          fontWeight: FontWeight.w700,
                          color: c.text2,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                YmMenuIconTrigger(
                  key: _menuKey,
                  isOpen: _menuOpen,
                  onTap: _openMenu,
                ),
              ],
            ),
          ),
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n is ScrollUpdateNotification) _updateReadingPage();
                if (n is ScrollEndNotification) {
                  // 停稳后再判一次：快速拖动时最后一帧的楼层可能还没铺出来，
                  // 滚动通知时点上拿到的视口顶是旧的
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _updateReadingPage();
                  });
                }
                if (n is UserScrollNotification &&
                    !_loading &&
                    _pendingPrepend == null &&
                    _scroll.hasClients) {
                  // 用户拖动才有方向（程序化滚动恒为 idle），触顶/触底才续载。
                  // ⚠ 方向枚举与直觉相反：reverse = 往列表深处滚（触底续载），
                  // forward = 往回滚（触顶补上一页）。
                  if (n.direction != ScrollDirection.idle) _userInteracted = true;
                  if (n.direction == ScrollDirection.forward &&
                      _hasPrev &&
                      _scroll.offset < 400) {
                    _load(_lowestPage - 1, prepend: true);
                  } else if (n.direction == ScrollDirection.reverse &&
                      _hasMore &&
                      _scroll.offset > _scroll.position.maxScrollExtent - 600) {
                    _load(_highestPage + 1);
                  }
                }
                return false;
              },
              child: ListView(
              key: _listKey,
              controller: _scroll,
              // 跳楼模式把预铺窗口从默认 250 放大到 4000：估算滚动范围靠铺出来的
              // 楼层校正，铺得越快收得越准（长文帖 20 楼一页的极端情形实测踩过）。
              // 补页量尺期间开全量窗口（挂底的量尺要活到量完高度那一帧）
              scrollCacheExtent:
                      _anchorPid.isNotEmpty || _pendingPrepend != null
                  ? const ScrollCacheExtent.pixels(100000)
                  : null,
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 86),
              children: [
                _buildTitleBlock(),
                if (_posts.isEmpty && _loading) const YmSkeletonRows(count: 4),
                if (_posts.isEmpty && !_loading && _error != null)
                  // 站方消息兜底（SITE_MESSAGE）：关站/维护/公告，摘站点原文、
                  // 中性标题、不做重试承诺。
                  // WAF：单按钮「去验证」收束（0.1.19 拍板），替代「重试」
                  YmStateView(
                    title: _errorCode == 'SITE_MESSAGE' ? '论坛暂时无法访问' : '帖子加载失败',
                    desc: _error,
                    actionLabel: _errorCode == 'SITE_MESSAGE'
                        ? null
                        : (_errorCode == 'WAF' ? '去验证' : '重试'),
                    onAction: _errorCode == 'WAF' ? _openWafVerify : () => _load(1),
                  ),
                for (final post in _posts)
                  YmForumPostCard(
                    key: _keyFor(post.pid),
                    post: post,
                    isOp: post.floor == 1,
                    commentsExpanded: _expandedComments.contains(post.pid),
                    onToggleComments: () => setState(() {
                      if (!_expandedComments.add(post.pid)) {
                        _expandedComments.remove(post.pid);
                      }
                    }),
                    onReply: _openWeb,
                    onOpenPoll: () => _openPollWeb(post),
                    onOpenImage: _openImage,
                    onOpenLink: _openLink,
                  ),
                // 单页帖（总页数 = 1）不出任何「加载更多」件：按钮挂上去
                // 只会诱发越界请求（站点原样回末页内容，0.1.23 实测）
                if (_totalPages != 1)
                  YmLoadMore(
                    loading: _loading,
                    hasMore: _hasMore,
                    doneText: _totalPages > 0
                        ? '已是最后一页 · 共 $_totalPages 页'
                        : '已全部加载',
                    onTap: () => _load(_highestPage + 1),
                  ),
                if (_error != null && _posts.isNotEmpty) YmTip(_error!),
                // 补页量尺：先挂在最底部量高度（offscreen，用户看不见），
                // 量完在 _finishPrepend 里搬到家顶部
                if (_pendingPrepend != null)
                  Column(
                    key: _prependedKey,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final post in _pendingPrepend!)
                        YmForumPostCard(
                          key: _keyFor(post.pid),
                          post: post,
                          isOp: post.floor == 1,
                          commentsExpanded: _expandedComments.contains(post.pid),
                          onToggleComments: () => setState(() {
                            if (!_expandedComments.add(post.pid)) {
                              _expandedComments.remove(post.pid);
                            }
                          }),
                          onReply: _openWeb,
                          onOpenPoll: () => _openPollWeb(post),
                          onOpenImage: _openImage,
                          onOpenLink: _openLink,
                        ),
                    ],
                  ),
              ],
            ),
            ),
          ),
          _buildReplyBar(),
        ],
      ),
    );
  }

  Widget _buildTitleBlock() {
    final c = YmScope.of(context).colors;
    return Padding(
      padding: const EdgeInsets.only(left: 2, right: 2, bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_tag.isNotEmpty)
            Container(
              // YmTag 口径：22 高 / pill（拆件表 C-01）
              height: 22,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: c.brandTint,
                borderRadius: BorderRadius.circular(YmRadius.pill),
              ),
              child: Text(
                _tag,
                style: TextStyle(
                  fontSize: YmFont.tag10,
                  fontWeight: FontWeight.w700,
                  color: c.brand,
                ),
              ),
            ),
          if (_title.isNotEmpty) ...[
            SizedBox(height: _tag.isNotEmpty ? 8 : 0),
            Text(
              _title,
              style: TextStyle(
                fontSize: YmFont.title23,
                fontWeight: FontWeight.w800,
                height: 1.3,
                color: c.text,
              ),
            ),
          ],
          if (_views > 0 || _replies > 0) ...[
            const SizedBox(height: 7),
            Text(
              '${_fmtCount(_views)} 浏览 · $_replies 回复',
              style: TextStyle(fontSize: YmFont.small12, color: c.text3),
            ),
          ],
        ],
      ),
    );
  }

  /// 收藏这条帖子（登录后可用；失败给人话不静默，写入只发一次）。
  Future<void> _favorite() async {
    if (_faving || _faved) return;
    if (ForumSession.loggedIn != true) {
      // 游客别只弹一句话：直接带去论坛登录，回来再点一次就行
      await Navigator.of(context).push(ymRoute(const ForumLoginPage(), snapshot: false));
      return;
    }
    setState(() => _faving = true);
    try {
      final r = await favoriteThread(widget.tid);
      if (!mounted) return;
      showYmToast(context, r.message);
      if (r.kind == ForumWriteKind.success) setState(() => _faved = true);
    } finally {
      if (mounted) setState(() => _faving = false);
    }
  }

  /// 追帖（本地能力，游客可用）：只翻本地 store 的 tracked 位，不写站点、不弹登录。
  /// 第一次追帖时若基线还没写（例如首载前就点），补写一条当前进度。
  void _toggleTrack() {
    final store = ForumTrackStore.instance;
    if (_tracked) {
      store.untrack(widget.tid);
      setState(() => _tracked = false);
      showYmToast(context, '已移出追帖');
      return;
    }
    store.track(
      tid: widget.tid,
      title: _title,
      boardName: _boardName,
      author: _posts.where((p) => p.floor == 1).firstOrNull?.author ?? '',
      replies: _replies,
    );
    setState(() => _tracked = true);
    showYmToast(context, '已加入追帖');
  }

  /// 阅读入口三态（可调，默认这套）：
  /// 1. 目录已知且 ≥3 条 → 显示；
  /// 2. 目录未知（从第 5 页恢复进来，没加载过首页）→ 照常显示，点的时候才去拉；
  /// 3. 目录已知且不足 3 条 → 收起（不占位，布局回退成原来的三段）。
  ///
  /// 首载完成前不显示：普通帖子先闪一下阅读钮、加载完又收起很难看；
  /// 恢复进入的帖子首载一完成（哪怕载的是第 5 页）就会按「未知」显示出来。
  bool get _readerEntryVisible {
    if (!_firstLoaded) return false;
    final toc = _toc;
    return toc == null || toc.length >= 3;
  }

  /// 点「阅读」：目录在内存里就直接弹层；不在就拉 page 1 判一次。
  Future<void> _openReaderEntry() async {
    if (_tocLoading) return;
    var toc = _toc;
    if (toc == null) {
      setState(() => _tocLoading = true);
      try {
        final data = await fetchForumThread(widget.tid, page: 1);
        if (!mounted) return;
        toc = data.toc;
        setState(() => _toc = toc);
      } catch (e) {
        if (!mounted) return;
        showYmToast(context, e is YmHttpError ? e.message : '目录加载失败');
        return;
      } finally {
        if (mounted) setState(() => _tocLoading = false);
      }
    }
    if (!mounted) return;
    if (toc.length < 3) {
      showYmToast(context, '这篇帖子没有章节目录');
      return;
    }
    _showReaderToc(toc);
  }

  /// 上次读到的章在本次目录里的下标；没进度 / 对不上返回 -1。
  /// 先按 pid 找（目录改过也能对上），再退保存的下标。
  int _resumeTocIndex(List<ForumTocEntry> toc) {
    final saved = ForumTrackStore.instance.recordOf(widget.tid);
    if (saved == null || saved.readerTocPid.isEmpty) return -1;
    final byPid = toc.indexWhere((e) => e.pid == saved.readerTocPid);
    if (byPid >= 0) return byPid;
    if (saved.readerTocIndex >= 0 && saved.readerTocIndex < toc.length) {
      return saved.readerTocIndex;
    }
    return -1;
  }

  /// 目录弹层：只做进阅读器的中转（topAction 继续阅读 + 目录列表），不跳楼。
  void _showReaderToc(List<ForumTocEntry> toc) {
    final chapters = <YmChapterRef>[
      for (final e in toc) YmChapterRef(id: e.pid, title: e.title, volume: ''),
    ];
    final resume = _resumeTocIndex(toc);
    showYmSheet<void>(
      context,
      builder: (ctx) => YmTocSheet(
        chapters: chapters,
        currentId: resume >= 0 ? toc[resume].pid : null,
        unit: '条',
        topAction: YmButton(
          kind: YmButtonKind.tint,
          height: 46,
          expanded: true,
          label: resume >= 0 ? '继续阅读 第 ${resume + 1} 章' : '从第一章开始',
          onTap: () {
            Navigator.of(ctx).pop();
            _openReader(toc, resume >= 0 ? resume : 0);
          },
        ),
        onPick: (ch) {
          final i = toc.indexWhere((e) => e.pid == ch.id);
          Navigator.of(ctx).pop();
          _openReader(toc, i < 0 ? 0 : i);
        },
      ),
    );
  }

  void _openReader(List<ForumTocEntry> toc, int index) {
    if (toc.isEmpty) return;
    final i = index < 0 ? 0 : (index >= toc.length ? toc.length - 1 : index);
    ymPush(
      context,
      ForumReaderPage(
        tid: widget.tid,
        title: _title,
        toc: toc,
        initialIndex: i,
      ),
    );
  }

  /// 底部回复条（草稿 `yf-replybar`）：假输入框 + 追帖钮 + 收藏钮，点了进网页壳。
  /// 0.1.36 起最左侧多一个「阅读」钮（作品帖的目录入口），与追帖 / 收藏同规格。
  Widget _buildReplyBar() {
    final c = YmScope.of(context).colors;
    return Container(
      decoration: BoxDecoration(
        color: c.topbarBg,
        border: Border(top: BorderSide(color: c.topbarBd)),
      ),
      padding: EdgeInsets.fromLTRB(14, 10, 14, 10 + MediaQuery.paddingOf(context).bottom),
      child: Row(
        children: [
          if (_readerEntryVisible) ...[
            // 阅读入口（用户拍板：底栏最左，不进菜单 / 顶栏）
            YmPressable(
              kind: YmPressKind.neutral,
              baseColor: c.fill,
              pressedColor: c.brandTint,
              radius: BorderRadius.circular(YmRadius.pill),
              onTap: _openReaderEntry,
              child: Container(
                height: 46,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                alignment: Alignment.center,
                child: Text(
                  '阅读',
                  style: TextStyle(
                    fontSize: YmFont.sub13,
                    fontWeight: FontWeight.w700,
                    color: c.text2,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: YmPressable(
              kind: YmPressKind.row,
              radius: BorderRadius.circular(YmRadius.pill),
              onTap: _openTopicWeb,
              child: Container(
                // 输入行档 46（ui-kit `.input`，拆件表 C-08；草稿 40 不在触控四档）
                height: 46,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                alignment: Alignment.centerLeft,
                decoration: BoxDecoration(
                  color: c.fill,
                  borderRadius: BorderRadius.circular(YmRadius.pill),
                ),
                // 三个按钮吃掉约 160dp，输入框只剩 140dp 上下：单行 + 省略，
                // 文案缩短到「回复…」（真机再按观感微调）
                child: Text(
                  '回复…',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: YmFont.sub13, color: c.text3),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 追帖钮：与收藏并列、同高同档，不替换收藏。游客可用。
          YmPressable(
            kind: YmPressKind.neutral,
            baseColor: c.fill,
            pressedColor: c.brandTint,
            radius: BorderRadius.circular(YmRadius.pill),
            onTap: _toggleTrack,
            child: Container(
              height: 46,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.center,
              child: Text(
                _tracked ? '已追帖' : '追帖',
                style: TextStyle(
                  fontSize: YmFont.sub13,
                  fontWeight: FontWeight.w700,
                  color: _tracked ? c.brand : c.text2,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 收藏钮：与假输入同高（46 输入行档），neutral 换底档
          YmPressable(
            kind: YmPressKind.neutral,
            baseColor: c.fill,
            pressedColor: c.brandTint,
            radius: BorderRadius.circular(YmRadius.pill),
            onTap: _favorite,
            child: Container(
              height: 46,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.center,
              child: Text(
                _faving ? '收藏中…' : (_faved ? '已收藏' : '收藏'),
                style: TextStyle(
                  fontSize: YmFont.sub13,
                  fontWeight: FontWeight.w700,
                  color: _faved ? c.brand : c.text2,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 计数缩写（≥1 万折「N 万」），与帖子行同一口径。
String _fmtCount(int n) {
  if (n >= 10000) {
    final v = (n / 10000).toStringAsFixed(1);
    return '${v.endsWith('.0') ? v.substring(0, v.length - 2) : v}万';
  }
  return '$n';
}

/// 列表行 → 帖子页的统一入口（首页热门区 / 板块页 / 之后的搜索都用它）。
void openForumThread(BuildContext context, ForumThreadSummary t) {
  ymPush(context, ForumThreadPage(tid: t.tid));
}
