# Yamibo-Flutter

⚠️ **石山代码注意**：本项目由 AI 辅助编写，代码中 AI 注释含量极高。

基于 RTGo 设计语言的百合会第三方客户端，由 Flutter 构建。

非官方项目，与站点运营方无隶属关系。

## 功能

- 小说、漫画：浏览与收藏
- 搜索：查找作品
- 论坛：帖子浏览、阅读模式
- 离线化：将漫画、小说、帖子保存到设备上
- 书架：分类筛选、一站式管理在看作品
- 深色模式、主题切换

## 构建

需要 Flutter 3.x。工程路径必须为纯 ASCII，含中文的路径会让 Android 构建直接失败。

```bash
flutter pub get
flutter build apk --release --split-per-abi
```

未提供签名配置：自行创建 `android/key.properties` 与 keystore，或在无该文件时构建 debug 包。目标 Android 7.0+（minSdk 24），arm64 包约 18MB。

## 许可

BSD-3-Clause，全文见 `LICENSE`。

界面派生自 RTGo 设计系统，其组件版权声明与许可见 `NOTICE.md`。

帖子、漫画、小说、图片及其他内容归原作者或相应权利人所有，使用时请遵守站点规则。
