import 'package:flutter/material.dart';

import '../design/ym_route.dart';
import '../dev/metrics.dart';

void ymPush(BuildContext context, Widget page) {
  ymBeginProbe('route', '路由 → 首帧完成');
  Navigator.of(context).push(ymRoute(page));
}
