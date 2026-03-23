import 'dart:async';
import 'dart:typed_data';

import 'package:opus_dart/opus_dart.dart';
import 'package:flutter_lame/flutter_lame.dart';

import 'length_prefixed_opus_packetizer.dart';


class StreamingOpusToMp3 {
  static const int _mp3FrameSize = 1152;

  final int sampleRate;
  final int channels;
  final int bitrate;

  late final LameMp3Encoder _encoder;

  /// 对外输出 MP3
  late final StreamController<Uint8List> _mp3Controller;
  Stream<Uint8List> get mp3Stream => _mp3Controller.stream;

  /// 内部 Opus 输入管线
  late final StreamController<Uint8List> _opusController;
  StreamSubscription? _opusSubscription;

  /// PCM ring buffer（Int16）
  final List<int> _pcm = [];

  StreamingOpusToMp3({
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

  /// 初始化 Opus → PCM → MP3 解码管线
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
      _onPcm,
      onError: (e, st) {
        _mp3Controller.addError(e, st);
      },
      onDone: () async {
        await _finalize();
      },
      cancelOnError: true,
    );
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// 推送一段 Opus 数据（push 模式）
  void addData(List<int> data) {
    if (_opusController.isClosed) return;

    _opusController.add(
      data is Uint8List ? data : Uint8List.fromList(data),
    );
  }

  /// 主动结束（非常重要）
  Future<void> finish() async {
    if (!_opusController.isClosed) {
      await _opusController.close();
    }
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  /// 接收 PCM s16le
  Future<void> _onPcm(Uint8List pcmBytes) async {
    final pcm = Int16List.view(
      pcmBytes.buffer,
      pcmBytes.offsetInBytes,
      pcmBytes.lengthInBytes ~/ 2,
    );

    _pcm.addAll(pcm);

    while (_pcm.length >= _mp3FrameSize * channels) {
      await _encodeFrame();
    }
  }

  /// 编码一个 MP3 帧（1152 samples）
  Future<void> _encodeFrame() async {
    final int samples = _mp3FrameSize;

    final Float64List left = Float64List(samples);
    Float64List? right = channels == 2 ? Float64List(samples) : null;

    for (int i = 0, j = 0; j < samples; j++, i += channels) {
      left[j] = _pcm[i] / 32768.0;
      if (channels == 2 && right != null) {
        right[j] = _pcm[i + 1] / 32768.0;
      }
    }

    _pcm.removeRange(0, samples * channels);

    final mp3 = await _encoder.encodeDouble(
      leftChannel: left,
      rightChannel: right,
    );

    if (mp3.isNotEmpty) {
      _mp3Controller.add(mp3);
    }
  }

  /// 收尾：flush MP3 + 关闭资源
  Future<void> _finalize() async {
    try {
      final tail = await _encoder.flush();
      if (tail.isNotEmpty) {
        _mp3Controller.add(tail);
      }
    } finally {
      await _mp3Controller.close();
      _encoder.close();
      await _opusSubscription?.cancel();
    }
  }
}
