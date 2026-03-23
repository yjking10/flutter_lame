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

  late final _splitter = OpusPacketSplitterBE32();
  late final _opusToOgg = StreamOpusToOgg(
    sampleRate: 16000,
    channels: 1,
    packetsPerPage: 10,
  );

  /// 模拟发送数据的方法
  Future<void> startSending() async {
    String fileName = '16_16_49';
    // String fileName = '11_06_59';

    // 1. 加载资源
    final ByteData opusByteData =
        await rootBundle.load('assets/audio/$fileName.opus');
    final Uint8List uint8list = opusByteData.buffer.asUint8List();
    final int totalLength = uint8list.length;

    // 1. 获取沙盒目录 (Documents)
    final directory = await getApplicationDocumentsDirectory();

    // 2. 构造完整路径
    final filePath = join(directory.path, '$fileName.ogg');
    final file = File(filePath);

    // 3. 确保父级目录存在 (如果是多级路径如 'audio/2024/test.opus')
    final parentDir = file.parent;
    if (!await parentDir.exists()) {
      await parentDir.create(recursive: true);
    }

    final sink = file.openWrite(mode: FileMode.append);

    _splitter.stream.listen(_opusToOgg.addOpus);

    _opusToOgg.stream.listen((page) {
      // 写文件 / 上传
      print(
          '写入文件: ${page.length} 字节 [${DateTime.now().millisecondsSinceEpoch ~/ 1000}]');

      sink.add(page);
    });

    print(
        '开始发送，总大小: ${totalLength} 字节 [${DateTime.now().millisecondsSinceEpoch ~/ 1000}]');
    _currentOffset = 0;

    // 2. 开启定时器
    _timer = Timer.periodic(_interval, (timer) {
      if (_currentOffset >= totalLength) {
        print('发送完毕 [${DateTime.now().millisecondsSinceEpoch ~/ 1000}]');
        _cancelTimer();
        //
        return;
      }

      // 计算本次截取的结束位置，防止越界
      int end = _currentOffset + _bytesPerPacket;
      if (end > totalLength) end = totalLength;

      // 截取数据分片 (Sublist)
      final chunk = uint8list.sublist(_currentOffset, end);

      // 执行发送逻辑
      _sendData(chunk);

      // 更新偏移量
      _currentOffset = end;

      // 打印进度 (可选)
      double progress = (_currentOffset / totalLength) * 100;
      print('已发送: ${progress.toStringAsFixed(1)}% | 块大小: ${chunk.length}');
    });
  }

  /// 实际的发送/处理逻辑（如通过 WebSocket 或打印）
  void _sendData(Uint8List data) {
    // 在这里对接你的业务逻辑，比如：
    // webSocket.add(data);
    print('Sending chunk of size: ${data.length} ');

    _splitter.add(data);
  }

  void stop() async {
    _cancelTimer();
     _splitter.close();
    await _opusToOgg.close();
  }

  void _cancelTimer() {
    if (_timer == null) return;
    _timer?.cancel();
    _timer = null;
    print('发送器已停止');
  }
}
