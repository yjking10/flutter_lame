import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

import 'opus_to_ogg.dart';

class OpusStreamSender {
  Timer? _timer;
  int _currentOffset = 0;

  // 常量定义
  static const int _totalBytesPerSecond = 2 * 1024 * 1024;
  static const Duration _interval = Duration(milliseconds: 100);
  static const int _bytesPerPacket =
      _totalBytesPerSecond ~/ (1000 ~/ 200); // 20KB

  late final _opusToOgg = OpusToOgg(
    sampleRate: 16000,
    channels: 1,
    packetsPerPage: 10,
  );

  IOSink? _sink;

  /// 模拟发送数据的方法
  Future<void> startSending() async {
    String fileName = 'input';

    // 1. 加载资源
    final ByteData opusByteData =
        await rootBundle.load('assets/audio/$fileName.raw');
    final Uint8List uint8list = opusByteData.buffer.asUint8List();
    final int totalLength = uint8list.length;

    // 1. 获取沙盒目录 (Documents)
    final directory = await getApplicationDocumentsDirectory();

    // 2. 构造完整路径
    final filePath = join(directory.path, '$fileName.ogg');
    final file = File(filePath);

    // 3. 确保父级目录存在
    final parentDir = file.parent;
    if (!await parentDir.exists()) {
      await parentDir.create(recursive: true);
    }

    _sink = file.openWrite(mode: FileMode.append);


    print(
        '开始发送，总大小: ${totalLength} 字节 [${DateTime.now().millisecondsSinceEpoch ~/ 1000}]');
    _currentOffset = 0;

    // 2. 开启定时器
    _timer = Timer.periodic(_interval, (timer) {
      if (_currentOffset >= totalLength) {
        print('发送完毕 [${DateTime.now().millisecondsSinceEpoch ~/ 1000}]');
        _cancelTimer();
        return;
      }

      // 计算本次截取的结束位置
      int end = _currentOffset + _bytesPerPacket;
      if (end > totalLength) end = totalLength;

      // 截取数据分片
      final chunk = uint8list.sublist(_currentOffset, end);

      // 执行发送逻辑
      _sendData(chunk);

      // 更新偏移量
      _currentOffset = end;

      // 打印进度
      double progress = (_currentOffset / totalLength) * 100;
      print('已发送: ${progress.toStringAsFixed(1)}% | 块大小: ${chunk.length}');
    });
  }

  /// 实际的发送/处理逻辑
  void _sendData(Uint8List data) {
    print('Sending chunk of size: ${data.length} ');

    // 1. 同步处理：直接调用 addOpus，内部已集成 Splitter 逻辑
    // 如果需要立即拿到转换后的 Ogg 数据，可以接收返回值：
    // final oggData = _opusToOgg.addOpus(data);
    final page = _opusToOgg.addOpus(data);

  _sink?.add(page);
    print(
        '写入文件: ${page.length} 字节 [${DateTime.now().millisecondsSinceEpoch ~/ 1000}]');

  }

  void stop() async {
    _cancelTimer();
    final page = _opusToOgg.flushAndClose();
    _sink?.add(page);
    await _sink?.flush();
    await _sink?.close();
  }

  void _cancelTimer() {
    if (_timer == null) return;
    _timer?.cancel();
    _timer = null;
    print('发送器已停止');
  }
}
