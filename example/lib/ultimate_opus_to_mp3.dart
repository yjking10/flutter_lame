
import 'dart:async';
import 'dart:typed_data';
import 'dart:collection';

import 'package:opus_dart/opus_dart.dart';
import 'package:flutter_lame/flutter_lame.dart';

import 'length_prefixed_opus_packetizer.dart';


const int kMp3FrameSize = 1152;
const int kMaxPcmSecondsBuffer = 10; // 只缓存 10 秒


class UltimateOpusToMp3 {
  final int sampleRate;
  final int channels;
  final int bitrate;

  late final LameMp3Encoder _encoder;
  late final StreamController<Uint8List> _mp3Controller;

  Stream<Uint8List> get mp3Stream => _mp3Controller.stream;

  late final StreamController<Uint8List> _opusController;
  StreamSubscription? _opusSubscription;

  UltimateOpusToMp3({
    this.sampleRate = 16000,
    this.channels = 1,
    this.bitrate = 32,
  }) {
    _mp3Controller = StreamController<Uint8List>();
    _opusController = StreamController<Uint8List>();

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
      onError: (e, st) => print("解码错误: $e"),
      onDone: _finalize,
      cancelOnError: true,
    );
  }

  bool _hasDataProcessed = false;
  bool _isFinishing = false;

  late final int _bytesPerFrame =
      kMp3FrameSize * channels * 2; // 16bit = 2 bytes
  bool _isProcessing = false;

  void addData(Uint8List data) {
    if (_opusController.isClosed) return;
    _hasDataProcessed = true;
    _opusController.add(data);
  }


  /// 使用 DoubleLinkedQueue 或 ListQueue 存储 Uint8List 分片，而不是单个字节
  final ListQueue<Uint8List> _pcmChunks = ListQueue<Uint8List>();
  int _currentBufferedSize = 0;



  void _onPcmReceived(Uint8List pcmBytes) {
    _pcmChunks.add(pcmBytes);
    _currentBufferedSize += pcmBytes.length;
    // print('_pcmBuffer total size: $_pcmSize');
    _startProcessingIfNeeded();
  }
  Future<void> _processLoop() async {
    final Uint8List frameBuffer = Uint8List(_bytesPerFrame);

    // 关键：在进入异步编码前，就完成数据的同步提取和长度扣除
    while (_currentBufferedSize >= _bytesPerFrame) {

      // --- 同步提取数据开始 ---
      int filled = 0;
      while (filled < _bytesPerFrame) {
        Uint8List firstChunk = _pcmChunks.removeFirst();
        int available = firstChunk.length;
        int need = _bytesPerFrame - filled;

        if (available <= need) {
          frameBuffer.setRange(filled, filled + available, firstChunk);
          filled += available;
        } else {
          frameBuffer.setRange(filled, _bytesPerFrame, firstChunk, 0);
          _pcmChunks.addFirst(Uint8List.sublistView(firstChunk, need));
          filled = _bytesPerFrame;
        }
      }

      // 立即扣除长度，确保即使 encode 阻塞，状态也是准确的
      _currentBufferedSize -= _bytesPerFrame;
      // --- 同步提取数据结束 ---

      try {
        final pcmData = Int16List.view(frameBuffer.buffer);

        // 这里的 await 不会影响 _currentBufferedSize 的准确性了
        Uint8List mp3;
        if (channels == 1) {
          // print('encode------');
          mp3 = await _encoder.encode(leftChannel: pcmData);
        } else {
          // MP3 帧固定为 1152 采样点/声道
          final int samplesPerChannel = kMp3FrameSize;
          final left = Int16List(samplesPerChannel);
          final right = Int16List(samplesPerChannel);
          for (int i = 0; i < samplesPerChannel; i++) {
            left[i] = pcmData[i * 2];
            right[i] = pcmData[i * 2 + 1];
          }
          mp3 = await _encoder.encode(leftChannel: left, rightChannel: right);
        }

        _mp3Controller.add(mp3);
      } catch (e) {
        print('Encoding error: $e');
      }
    }
  }

  Completer<void>? _processingCompleter;

  /// 2. 启动处理协程
  void _startProcessingIfNeeded() {
    if (_isProcessing) return;

    _isProcessing = true;
    _processingCompleter ??= Completer<void>();

    _processLoop().then((_) {
      _isProcessing = false;

      if (_currentBufferedSize >= _bytesPerFrame) {
        // 还有数据，继续跑
        _startProcessingIfNeeded();
      } else {
        // 真正结束
        _processingCompleter?.complete();
        _processingCompleter = null;
      }
    });
  }

  Future<void> finish() async {
    if (_isFinishing) return;
    _isFinishing = true;

    await _finalize();

    if (!_opusController.isClosed) await _opusController.close();
  }

  // bool _isFinalized = false;

  Future<void> _finalize() async {
    if (_isProcessing) {
      await _processingCompleter?.future;
    }

    if (_hasDataProcessed) {
      final tail = await _encoder.flush();
      if (tail.isNotEmpty) {
        _mp3Controller.add(tail);
      }
    }

    await _mp3Controller.close();
    await _encoder.close();

    // 关键释放
    _pcmChunks.clear();
    _currentBufferedSize = 0;

    _opusSubscription?.cancel();
    _opusSubscription = null;
  }
}