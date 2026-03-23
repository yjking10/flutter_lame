import 'dart:async';
import 'dart:typed_data';
import 'dart:collection';

import 'package:opus_dart/opus_dart.dart';
import 'package:flutter_lame/flutter_lame.dart';

import 'length_prefixed_opus_packetizer.dart';

class StreamingOpusToMp3 {
  static const int _mp3FrameSize = 1152;
  static const int _maxConcurrentEncodes = 50;
  static const int _maxBufferDuration = 60;

  final int sampleRate;
  final int channels;
  final int bitrate;

  late final LameMp3Encoder _encoder;

  late final StreamController<Uint8List> _mp3Controller;

  Stream<Uint8List> get mp3Stream => _mp3Controller.stream;

  late final StreamController<Uint8List> _opusController;
  StreamSubscription? _opusSubscription;

  late Int16List _circularBuffer;
  int _readIndex = 0;
  int _writeIndex = 0;
  int _currentLength = 0;

  int _activeEncodeCount = 0;
  bool _isPaused = false;

  int _nextFrameId = 0;
  int _nextExpectedId = 0;
  final SplayTreeMap<int, Uint8List> _pendingFrames = SplayTreeMap();

  StreamingOpusToMp3({
    this.sampleRate = 16000,
    this.channels = 1,
    this.bitrate = 32,
  }) {
    _mp3Controller = StreamController<Uint8List>();
    _opusController = StreamController<Uint8List>();

    _circularBuffer = Int16List(sampleRate * channels * _maxBufferDuration);

    _encoder = LameMp3Encoder(
      sampleRate: sampleRate,
      numChannels: channels,
      bitRate: bitrate,
    );

    _initPipeline();
  }

  void _initPipeline() {
    _opusSubscription = _opusController.stream
        .transform(LengthPrefixedOpusPacketizer())
        .cast<Uint8List?>()
        .transform(
      StreamOpusDecoder.bytes(
        floatOutput: false,
        sampleRate: sampleRate,
        channels: channels,
        copyOutput: true,
      ),
    )
        .cast<Uint8List>()
        .listen(
      _onPcmReceived,
      onError: (e, st) {
        print("解码管线错误: $e");
        if (!_mp3Controller.isClosed) _mp3Controller.addError(e, st);
      },
      onDone: () async {
        await _finalize();
      },
      cancelOnError: true,
    );
  }

  bool _hasDataProcessed = false;
  bool _isFinishing = false;

  void addData(Uint8List data) {
    if (_opusController.isClosed) return;
    _hasDataProcessed = true;
    _opusController.add(data);
  }

  Future<void> finish() async {
    if (_isFinishing) return;
    _isFinishing = true;

    print("调用 finish, hasData: $_hasDataProcessed");

    if (!_opusController.isClosed) {
      await _opusController.close();
    }

    if (!_hasDataProcessed) {
      print("无数据输入，直接执行强制清理");
      await _finalize();
    }

    await _mp3Controller.done.timeout(
      const Duration(milliseconds: 2500),
      onTimeout: () => print("finish 等待超时，强制退出"),
    );

    print("Streaming 任务彻底结束");
  }

  Future<void> _onPcmReceived(Uint8List pcmBytes) async {
    final incomingPcm = Int16List.view(
      pcmBytes.buffer,
      pcmBytes.offsetInBytes,
      pcmBytes.lengthInBytes ~/ 2,
    );
    print('接收到pcm ${pcmBytes.length}, 缓冲: $_currentLength');

    for (int i = 0; i < incomingPcm.length; i++) {
      _circularBuffer[_writeIndex] = incomingPcm[i];
      _writeIndex = (_writeIndex + 1) % _circularBuffer.length;
      _currentLength++;

      if (_currentLength > _circularBuffer.length) {
        _readIndex = (_readIndex + 1) % _circularBuffer.length;
        _currentLength--;
        print('⚠️ 缓冲区溢出！丢失数据');
      }
    }

    // 1. 只有当缓冲区真的快溢出时才暂停（例如用了 8 秒的量）
    if (_currentLength > sampleRate * channels * 8 && !_isPaused) {
      _isPaused = true;
      _opusSubscription?.pause();
      print('⚠️ 缓冲区接近临界值，暂停输入');
    }

    // 2. 只要有数据且并发没到极限，就疯狂启动编码
    _triggerEncoding();

  }

  void _triggerEncoding() {
    final int frameSize = _mp3FrameSize * channels;
    while (_currentLength >= frameSize &&
        _activeEncodeCount < _maxConcurrentEncodes) {
      _encodeFrameAsync();
    }
  }

  void _encodeFrameAsync() {
    _activeEncodeCount++;
    final int frameId = _nextFrameId++;

    print('🔵 启动编码任务 #$frameId 当前编码任务=$_activeEncodeCount');

    // _encodeFrame().then((mp3Data) {
    //   _activeEncodeCount--;
    //   // print('✅ 编码任务 #$frameId 完成 (${mp3Data.length} bytes)');
    //
    //   _enqueueAndFlush(frameId, mp3Data);
    //
    //   if (_isPaused && _activeEncodeCount < _maxConcurrentEncodes) {
    //     _isPaused = false;
    //     _opusSubscription?.resume();
    //     // print('▶️ 编码恢复，继续输入流');
    //   }
    //
    //   final int frameSize = _mp3FrameSize * channels;
    //   if (_currentLength >= frameSize &&
    //       _activeEncodeCount < _maxConcurrentEncodes) {
    //     _encodeFrameAsync();
    //   }
    // }).catchError((e) {
    //   _activeEncodeCount--;
    //   print('编码错误 #$frameId: $e');
    // });


    _encodeFrame().then((mp3Data) {
      print('✅ 编码任务 #$frameId 完成 (${mp3Data.length} bytes)');
      _activeEncodeCount--;
      _enqueueAndFlush(frameId, mp3Data);

      // ✨ 关键：编码完成后，立刻检查缓冲区是否还有积压，实现自驱动
      _triggerEncoding();
    }).catchError((e) {
      _activeEncodeCount--;
      print('编码错误 #$frameId: $e');
    });

  }

  void _enqueueAndFlush(int frameId, Uint8List mp3Data) {
    _pendingFrames[frameId] = mp3Data;

    while (_pendingFrames.containsKey(_nextExpectedId)) {
      final data = _pendingFrames.remove(_nextExpectedId)!;

      if (!_mp3Controller.isClosed) {
        _mp3Controller.add(data);
        // print('📤 输出帧 #$_nextExpectedId (${data.length} bytes)');
      }

      _nextExpectedId++;
    }

    if (_pendingFrames.isNotEmpty) {
      print(
          '⏳ 等待帧: ${_pendingFrames.keys.take(3).join(", ")}... (共${_pendingFrames.length}个)');
    }
  }

  Future<Uint8List> _encodeFrame() async {
    const int samples = _mp3FrameSize;

    final Int16List left = Int16List(samples);
    Int16List? right = channels == 2 ? Int16List(samples) : null;

    for (int j = 0; j < samples; j++) {
      left[j] = _circularBuffer[_readIndex];
      _readIndex = (_readIndex + 1) % _circularBuffer.length;

      if (channels == 2 && right != null) {
        right[j] = _circularBuffer[_readIndex];
        _readIndex = (_readIndex + 1) % _circularBuffer.length;
      }
    }

    _currentLength -= (samples * channels);

    final mp3 = await _encoder.encode(
      leftChannel: left,
      rightChannel: right,
    );

    return mp3;
  }

  // ✅ 新增：处理不足一帧的剩余数据（零填充）
  Future<Uint8List> _encodePartialFrame(int remainingSamples) async {
    print('🔶 处理剩余数据: $remainingSamples samples (不足完整帧)');

    const int samples = _mp3FrameSize;

    // 创建完整帧大小的缓冲区，自动零填充
    final Int16List left = Int16List(samples); // 默认全为0
    Int16List? right = channels == 2 ? Int16List(samples) : null;

    // 从循环缓冲区提取实际数据
    final int actualSamples = remainingSamples ~/ channels;
    for (int j = 0; j < actualSamples; j++) {
      left[j] = _circularBuffer[_readIndex];
      _readIndex = (_readIndex + 1) % _circularBuffer.length;

      if (channels == 2 && right != null) {
        right[j] = _circularBuffer[_readIndex];
        _readIndex = (_readIndex + 1) % _circularBuffer.length;
      }
    }

    _currentLength -= remainingSamples;

    // 编码（多余部分已自动零填充）
    final mp3 = await _encoder.encode(
      leftChannel: left,
      rightChannel: right,
    );

    print(
        '✅ 剩余数据编码完成: ${mp3.length} bytes (填充了 ${samples - actualSamples} 零样本)');
    return mp3;
  }

  bool _isFinalized = false;

  Future<void> _finalize() async {
    if (_isFinalized) return;
    _isFinalized = true;

    try {
      print('🔚 开始收尾: 缓冲区剩余 $_currentLength samples');

      // 1. 等待所有正在进行的编码任务完成
      while (_activeEncodeCount > 0) {
        print('⏳ 等待 $_activeEncodeCount 个编码任务完成...');
        await Future.delayed(const Duration(milliseconds: 50));
      }

      // 2. ✅ 处理缓冲区中所有完整帧
      final int frameSize = _mp3FrameSize * channels;
      while (_currentLength >= frameSize) {
        final int frameId = _nextFrameId++;
        print('🔵 收尾：编码完整帧 #$frameId');
        final mp3Data = await _encodeFrame();
        _enqueueAndFlush(frameId, mp3Data);
      }

      // 3. ✅ **关键改进**：处理不足一帧的剩余数据
      if (_currentLength > 0) {
        final int frameId = _nextFrameId++;
        print('🔶 收尾：编码剩余 $_currentLength samples (ID #$frameId)');
        final mp3Data = await _encodePartialFrame(_currentLength);
        _enqueueAndFlush(frameId, mp3Data);
      }

      // 4. 检查待输出队列
      if (_pendingFrames.isNotEmpty) {
        print('⚠️ 仍有 ${_pendingFrames.length} 帧未输出：${_pendingFrames.keys}');
        // 强制输出剩余帧（异常情况处理）
        for (var entry in _pendingFrames.entries) {
          if (!_mp3Controller.isClosed) {
            _mp3Controller.add(entry.value);
            print('⚠️ 强制输出帧 #${entry.key}');
          }
        }
        _pendingFrames.clear();
      }

      // 5. 调用编码器 flush（处理编码器内部缓冲）
      if (_hasDataProcessed) {
        final tail = await _encoder.flush();
        if (tail.isNotEmpty && !_mp3Controller.isClosed) {
          _mp3Controller.add(tail);
          print('📤 输出编码器 flush 数据 (${tail.length} bytes)');
        }
      }

      print('✅ 缓冲区数据已全部编码，最终剩余: $_currentLength samples');
    } catch (e, st) {
      print("收尾转码失败: $e\n$st");
    } finally {
      if (!_mp3Controller.isClosed) await _mp3Controller.close();
      _encoder.close();
      await _opusSubscription?.cancel();
    }
  }
}




