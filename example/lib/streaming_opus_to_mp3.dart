import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:opus_dart/opus_dart.dart';
import 'package:flutter_lame/flutter_lame.dart';

class StreamingOpusToMp3 {
  static const int _mp3FrameSize = 1152;

  final int sampleRate;
  final int channels;
  final int bitrate;

  late final LameMp3Encoder _encoder;
  late final IOSink _sink;

  /// PCM ring buffer（Int16）
  final List<int> _pcm = [];

  StreamingOpusToMp3({
    required String outputMp3Path,
    this.sampleRate = 16000,
    this.channels = 1,
    this.bitrate = 32,
  }) {
    final file = File(outputMp3Path);
    if (file.existsSync()) file.deleteSync();

    _sink = file.openWrite();
    _encoder = LameMp3Encoder(
      sampleRate: sampleRate,
      numChannels: channels,
      bitRate: bitrate,
    );
  }

  /// 主处理入口：Opus packet stream
  Future<void> process(Stream<Uint8List> rawStream) async {
    await rawStream
    // ① 拆 length-prefixed opus packet
        .transform(LengthPrefixedOpusPacketizer())

    // ② decoder 需要 Uint8List?
        .cast<Uint8List?>()

    // ③ opus → pcm
        .transform(
      StreamOpusDecoder.bytes(
        floatOutput: false,
        sampleRate: sampleRate,
        channels: channels,
        copyOutput: true,
      ),
    )

    // ④ pcm bytes
        .cast<Uint8List>()

    // ⑤ pcm → mp3
        .forEach(_onPcm);


  }

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

  /// 编码一个 MP3 帧（严格 1152）
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
      _sink.add(mp3);
    }
  }

  /// 结束流（必须调用）
  Future<void> finish() async {
    final tail = await _encoder.flush();
    if (tail.isNotEmpty) {
      _sink.add(tail);
    }
    await _sink.close();
    _encoder.close();
  }
}




class LengthPrefixedOpusPacketizer
    extends StreamTransformerBase<Uint8List, Uint8List> {
  final List<int> _buffer = [];

  @override
  Stream<Uint8List> bind(Stream<Uint8List> stream) async* {
    await for (final chunk in stream) {
      _buffer.addAll(chunk);

      while (true) {
        // 1️⃣ 不够 4 字节，等下一包
        if (_buffer.length < 4) break;

        // 2️⃣ 解析长度（big-endian）
        final int length =
        (_buffer[0] << 24) |
        (_buffer[1] << 16) |
        (_buffer[2] << 8) |
        _buffer[3];

        // 3️⃣ 不够一个完整 opus packet
        if (_buffer.length < 4 + length) break;

        // 4️⃣ 切出 opus packet
        final packet = Uint8List.fromList(
          _buffer.sublist(4, 4 + length),
        );

        // 5️⃣ 移除已消费数据
        _buffer.removeRange(0, 4 + length);

        yield packet;
      }
    }
  }
}