import 'package:flutter/material.dart';

import '../../data/http.dart';
import '../../data/library.dart';
import '../../data/session.dart';
import '../../data/write.dart';
import 'button.dart';
import 'rows.dart';
import 'sheet.dart';
import 'toast.dart';

/// 详情页的操作块：`阅读 / 加入书架 / 收藏` 三颗按钮 + 下面那排数字格。
///
/// 小说与漫画详情页的这一块**完全同构**，只差 `kind`，所以收在一处 ——
/// 「收藏」这套翻转语义的调用（要带当前状态、要 CSRF、失败要能区分登录失效）
/// 只该有一份实现。
///
/// 三颗按钮的口径：
/// - 阅读：撑满剩余宽（继续阅读 / 开始阅读）；
/// - 加入书架：96px tint，本机书架（`ym_shelf_v1`），与站内无关；
/// - 收藏：96px tint，站内收藏（`/fav/work`），**翻转**接口。
///
/// ⚠ 收藏要用 [YmWrite.setFav] 而不是 `toggleFav`：前者拿 [favored] 比对，
/// 状态已一致就**不发请求**（否则一次误触把用户的操作反向抵消）。
class YmDetailActions extends StatefulWidget {
  const YmDetailActions({
    super.key,
    required this.workId,
    required this.manga,
    required this.title,
    required this.author,
    required this.cover,
    required this.primaryLabel,
    required this.onRead,
    required this.csrfToken,
    required this.favored,
    required this.hits,
    required this.favs,
    required this.score,
    required this.onLogin,
    this.onFavoredChanged,
    this.locked = false,
  });

  final String workId;
  final bool manga;

  /// 书架条目要存的三个字段（书名 / 作者 / 封面）。
  final String title;
  final String author;
  final String cover;

  final String primaryLabel;
  final VoidCallback onRead;

  /// 详情页解析时顺手带回来的 CSRF token；空串时写通道自己回源取一次。
  final String csrfToken;

  /// 当前是否已收藏（见 `parseFavored`）。
  final bool favored;

  final String hits;
  final String favs;
  final String score;

  final VoidCallback onLogin;

  /// 收藏状态翻转后回传（页面要记着，免得下次重建又拿旧模型覆盖）。
  final ValueChanged<bool>? onFavoredChanged;

  /// **数据还没换成在线版本**（本地优先的首帧 / 刷新失败）时置 true：
  /// 服务端写操作先不放行 —— 本机副本里的 CSRF 令牌可能是旧的，点下去只会
  /// 拿到「登录失效」。硬点只回一句「正在更新数据…」，不做假成功。
  /// 「加入书架」不受影响（那是存在手机里的，离线本来就该能用）。
  final bool locked;

  @override
  State<YmDetailActions> createState() => _YmDetailActionsState();
}

class _YmDetailActionsState extends State<YmDetailActions> {
  late bool _favored = widget.favored;
  late String _favs = widget.favs;
  bool _busy = false;

  @override
  void didUpdateWidget(YmDetailActions old) {
    super.didUpdateWidget(old);
    // 详情重新取回来了（比如换了作品）⇒ 以站点的说法为准
    if (old.favored != widget.favored) _favored = widget.favored;
    if (old.favs != widget.favs) _favs = widget.favs;
  }

  void _toast(String text) {
    showYmToast(context, text);
  }

  /// 收藏数跟着翻转做本地加减：站点不给实时数，重新取一次详情只为这个不值当。
  String _shiftCount(String raw, int delta) {
    final n = int.tryParse(raw.replaceAll(',', ''));
    if (n == null) return raw; // 站点给的不是数字（如「—」）就别硬算
    final next = n + delta;
    return next < 0 ? '0' : '$next';
  }

  Future<void> _toggleFav() async {
    if (_busy) return;
    if (widget.locked) {
      // 本机副本里的令牌可能已过期：等服务换到在线版本再放行
      _toast('正在更新数据…');
      return;
    }
    if (!YmSession.loggedIn) {
      final go = await showYmConfirm(
        context,
        title: '登录后才能收藏',
        content: '收藏记在站内账号上，登录后即可使用。',
        confirmText: '去登录',
        cancelText: '算了',
      );
      if (go == true) widget.onLogin();
      return;
    }

    final want = !_favored;
    setState(() => _busy = true);
    try {
      final r = await YmWrite.setFav(
        workId: widget.workId,
        manga: widget.manga,
        on: want,
        currently: _favored,
        csrfToken: widget.csrfToken,
      );
      if (!mounted) return;
      if (!r.ok) {
        // 站点回了 succ=false（比如会话过期但它给的仍是 200）
        await showYmAlert(context, title: '没能收藏', content: r.msg.isEmpty ? '请稍后再试。' : r.msg);
        return;
      }
      setState(() {
        _favored = r.on;
        _favs = _shiftCount(_favs, r.on ? 1 : -1);
      });
      widget.onFavoredChanged?.call(r.on);
      _toast(r.on ? '已收藏' : '已取消收藏');
    } on YmHttpError catch (e) {
      if (!mounted) return;
      if (e.isLoginRequired) {
        final go = await showYmConfirm(
          context,
          title: '登录已失效',
          content: '重新登录后再试一次。',
          confirmText: '去登录',
          cancelText: '算了',
        );
        if (go == true) widget.onLogin();
        return;
      }
      await showYmAlert(context, title: '没能收藏', content: e.message);
    } catch (_) {
      if (!mounted) return;
      await showYmAlert(context, title: '没能收藏', content: '请稍后再试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: YmLibrary.instance,
      builder: (context, _) {
        final onShelf = YmLibrary.instance.onShelf(widget.workId);
        return Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: YmButton(
                    kind: YmButtonKind.primary,
                    label: widget.primaryLabel,
                    expanded: true,
                    onTap: widget.onRead,
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 96,
                  child: YmButton(
                    label: onShelf ? '移出书架' : '加入书架',
                    kind: YmButtonKind.tint,
                    onTap: () {
                      YmLibrary.instance.toggleShelf(
                        widget.workId,
                        title: widget.title,
                        author: widget.author,
                        kind: widget.manga ? 'manga' : 'novel',
                        cover: widget.cover,
                      );
                      _toast(onShelf ? '已移出书架' : '已加入书架');
                    },
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 96,
                  child: YmButton(
                    // 站点原版就是这个口径：未收藏「加入收藏」/ 已收藏「取消收藏」
                    label: _favored ? '取消收藏' : '加入收藏',
                    kind: YmButtonKind.tint,
                    onTap: _toggleFav,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(child: YmFact(k: '点击', v: widget.hits)),
                const SizedBox(width: 8),
                Expanded(child: YmFact(k: '收藏', v: _favs)),
                const SizedBox(width: 8),
                Expanded(child: YmFact(k: '评分', v: widget.score)),
              ],
            ),
          ],
        );
      },
    );
  }
}
