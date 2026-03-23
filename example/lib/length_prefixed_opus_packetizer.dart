
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:opus_dart/opus_dart.dart';
import 'package:flutter_lame/flutter_lame.dart';

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