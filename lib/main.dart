import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'data/auth.dart';
import 'data/cache/download_queue.dart';
import 'data/cache/ym_cache_store.dart';
import 'data/forum/forum_auth.dart';
import 'data/forum/forum_track.dart';
import 'data/library.dart';
import 'data/manga_prefs.dart';
import 'data/reader_prefs.dart';
import 'data/session.dart';
import 'data/theme_prefs.dart';
import 'dev/metrics.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  ymInitMetrics();
  // 先读会话（Cookie / 登录态）、书库（书架 / 阅读历史）、漫画阅读偏好与配色方案再起界面
  await YmSession.load();
  // 论坛登录态单独一份（论坛罐，落盘 forum_session.json），重启后论坛侧仍保持登录
  await ForumSession.load();
  // 论坛追帖 / 阅读历史（ym_forum_track.json），与书库两套数据互不读写
  await ForumTrackStore.load();
  await YmLibrary.load();
  // 文字阅读偏好（字号 / 行距 / 简繁 / 翻页模式，ym_reader_prefs.json）
  await YmReaderPrefs.load();
  await YmMangaPrefs.load();
  await YmThemePrefs.load();
  // 离线缓存（ym_cache/index.json 与 queue.json）。队列读回来一律标 paused，
  // 不自动续跑 —— 没有前台服务，自动跑会跟用户抢网（缓存第一期 §任务3）。
  await YmCache.load();
  await YmDownloadQueue.load();
  runApp(const YamiboApp());
  // 界面起来后再回站校验（游客不发请求；断网保持本地登录态，不踢人下线）
  unawaited(YmAuth.verifyOnLaunch());
}
