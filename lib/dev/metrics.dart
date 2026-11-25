import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 切片验收用的轻量指标：只测「输入 → 首个完成构图的帧」。
/// 不参与业务逻辑，正式工程可以整文件删掉。
class YmMetric {
  const YmMetric({required this.label, required this.ms, required this.frames});

  final String label;
  final double ms;
  final int frames;
}

class YmMetricStore extends ChangeNotifier {
  final Map<String, YmMetric> _items = {};

  List<YmMetric> get all => _items.values.toList(growable: false);

  YmMetric? operator [](String key) => _items[key];

  void record(String key, YmMetric metric) {
    _items[key] = metric;
    notifyListeners();
  }
}

final ymMetrics = YmMetricStore();

class _ProbeEngine {
  bool _active = false;
  int _frames = 0;
  Stopwatch? _watch;
  String? _key;

  void init() {
    SchedulerBinding.instance.addPersistentFrameCallback((_) {
      if (_active) _frames++;
    });
  }

  void begin(String key, String label) {
    // 已有一次测量在等帧时，直接覆盖上一次（人不该在同一帧按两次）
    _active = true;
    _frames = 0;
    _key = key;
    _watch = Stopwatch()..start();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!_active || _key != key) return;
      _active = false;
      final ms = (_watch?.elapsedMicroseconds ?? 0) / 1000;
      ymMetrics.record(key, YmMetric(label: label, ms: ms, frames: _frames));
    });
  }
}

final _probes = _ProbeEngine();

/// 在触发状态变更**之前**调用，回调里记录到首个完成构图的帧。
void ymBeginProbe(String key, String label) => _probes.begin(key, label);

/// 帧耗时（build / raster），近 30 帧平均。
class YmFrameStats extends ChangeNotifier {
  final List<double> _build = [];
  final List<double> _raster = [];

  double? get avgBuildMs => _avg(_build);
  double? get avgRasterMs => _avg(_raster);

  void add(FrameTiming timing) {
    _build.add(timing.buildDuration.inMicroseconds / 1000);
    _raster.add(timing.rasterDuration.inMicroseconds / 1000);
    if (_build.length > 30) _build.removeAt(0);
    if (_raster.length > 30) _raster.removeAt(0);
    notifyListeners();
  }

  double? _avg(List<double> v) {
    if (v.isEmpty) return null;
    return v.reduce((a, b) => a + b) / v.length;
  }
}

final ymFrameStats = YmFrameStats();

void ymInitMetrics() {
  _probes.init();
  SchedulerBinding.instance.addTimingsCallback((timings) {
    for (final t in timings) {
      ymFrameStats.add(t);
    }
  });
}
