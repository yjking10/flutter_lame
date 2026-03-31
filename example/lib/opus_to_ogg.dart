import 'dart:async';
import 'dart:typed_data';

class OggCrc32 {
  static final List<int> _table = _createTable();

  static List<int> _createTable() {
    const poly = 0x04C11DB7;
    final table = List<int>.filled(256, 0);
    for (int i = 0; i < 256; i++) {
      int r = i << 24;
      for (int j = 0; j < 8; j++) {
        r = (r & 0x80000000 != 0) ? (r << 1) ^ poly : r << 1;
      }
      table[i] = r & 0xffffffff;
    }
    return table;
  }

  static int compute(Uint8List data) {
    int crc = 0;
    for (final b in data) {
      crc = ((crc << 8) ^ _table[((crc >> 24) ^ b) & 0xff]) & 0xffffffff;
    }
    return crc;
  }
}

class OggPageBuilder {
  int _sequence = 0;
  final int _serial = DateTime.now().millisecondsSinceEpoch & 0xffffffff;

  Uint8List buildPage({
    required List<Uint8List> packets,
    required int granulePos,
    required int headerType,
  }) {
    final segmentTable = <int>[];
    final body = BytesBuilder();

    for (final p in packets) {
      int size = p.length;
      while (size >= 255) {
        segmentTable.add(255);
        size -= 255;
      }
      segmentTable.add(size);
      body.add(p);
    }

    final header = BytesBuilder();
    header.add([0x4f, 0x67, 0x67, 0x53]); // "OggS"
    header.addByte(0); // version
    header.addByte(headerType);
    header.add(_int64LE(granulePos));
    header.add(_int32LE(_serial));
    header.add(_int32LE(_sequence++));
    header.add([0, 0, 0, 0]); // CRC Placeholder (MUST BE 0)
    header.addByte(segmentTable.length);
    header.add(Uint8List.fromList(segmentTable));

    final pageBytes = BytesBuilder();
    pageBytes.add(header.toBytes());
    pageBytes.add(body.toBytes());

    final data = pageBytes.toBytes();

    // 关键修复：确保 CRC 区域在计算前为 0
    data[22] = 0; data[23] = 0; data[24] = 0; data[25] = 0;

    final crc = OggCrc32.compute(data);

    // 填入计算结果
    final crcBytes = _int32LE(crc);
    data[22] = crcBytes[0];
    data[23] = crcBytes[1];
    data[24] = crcBytes[2];
    data[25] = crcBytes[3];

    return data;
  }

  Uint8List _int32LE(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);
  Uint8List _int64LE(int v) => Uint8List(8)..buffer.asByteData().setUint64(0, v, Endian.little);
}

class OpusToOgg {
  final int sampleRate;
  final int channels;
  final int packetsPerPage;

  final StreamController<Uint8List> _controller = StreamController.broadcast();
  Stream<Uint8List> get stream => _controller.stream;

  final OggPageBuilder _ogg = OggPageBuilder();
  final List<Uint8List> _packetBuffer = [];
  int _granulePos = 0;
  bool _headerSent = false;

  // Splitter logic integrated
  final List<Uint8List> _inputChunks = [];
  int _inputTotalLength = 0;

  OpusToOgg({
    this.sampleRate = 16000,
    this.channels = 1,
    this.packetsPerPage = 10,
  });

  int get _step48k => (48000 * 0.02).toInt();

  /// 同步处理输入的原始数据块（包含 4 字节 BigEndian 长度头）
  /// 内部会自动拆解成 Opus 包并封装成 Ogg 页
  Uint8List addOpus(Uint8List data) {
    if (data.isEmpty) return Uint8List(0);
    
    _inputChunks.add(data);
    _inputTotalLength += data.length;

    final outputBuilder = BytesBuilder();

    // 循环提取完整的 Opus 包并处理
    while (_inputTotalLength >= 4) {
      final header = _peekBytes(4);
      final packetLen = (header[0] << 24) | (header[1] << 16) | (header[2] << 8) | header[3];

      if (packetLen <= 0 || packetLen > 65535) {
        // 数据异常，清空缓存
        _inputChunks.clear();
        _inputTotalLength = 0;
        break;
      }

      if (_inputTotalLength < 4 + packetLen) break;

      _consume(4);
      final packet = _readBytes(packetLen);
      
      // 处理提取出的单个 Opus 包，生成 Ogg 数据块
      outputBuilder.add(_processPacket(packet));
    }

    final result = outputBuilder.toBytes();
    if (result.isNotEmpty) {
      _controller.add(result);
    }
    return result;
  }

  /// 处理单个 Opus 包
  Uint8List _processPacket(Uint8List packet) {
    final builder = BytesBuilder();

    if (!_headerSent) {
      builder.add(_sendHeaders());
      _headerSent = true;
    }

    _packetBuffer.add(packet);

    if (_packetBuffer.length >= packetsPerPage) {
      builder.add(_flushPage(isLast: false));
    }

    return builder.toBytes();
  }

  Uint8List _flushPage({bool isLast = false}) {
    if (_packetBuffer.isEmpty && !isLast) return Uint8List(0);

    _granulePos += _step48k * _packetBuffer.length;

    final page = _ogg.buildPage(
      packets: List.from(_packetBuffer),
      granulePos: _granulePos,
      headerType: isLast ? 0x04 : 0x00,
    );

    _packetBuffer.clear();
    return page;
  }

  Uint8List _sendHeaders() {
    final builder = BytesBuilder();

    // Page 1: ID Header (BOS)
    builder.add(_ogg.buildPage(
      packets: [_buildOpusHead()],
      granulePos: 0,
      headerType: 0x02,
    ));

    // Page 2: Comment Header
    builder.add(_ogg.buildPage(
      packets: [_buildOpusTags()],
      granulePos: 0,
      headerType: 0x00,
    ));

    return builder.toBytes();
  }

  Uint8List flushAndClose() {
    final lastPage = _flushPage(isLast: true);
    if (lastPage.isNotEmpty) {
      _controller.add(lastPage);
    }
    _controller.close();
    return lastPage;
  }

  @Deprecated('Use flushAndClose instead')
  Future<void> close() async {
    flushAndClose();
    await Future.delayed(const Duration(milliseconds: 50));
  }

  Uint8List _buildOpusHead() {
    final b = BytesBuilder();
    b.add("OpusHead".codeUnits);
    b.addByte(1); // Version
    b.addByte(channels);
    b.add(Uint8List(2)..buffer.asByteData().setUint16(0, 312, Endian.little)); // Pre-skip
    b.add(Uint8List(4)..buffer.asByteData().setUint32(0, sampleRate, Endian.little)); // Original Rate
    b.add(Uint8List(2)..buffer.asByteData().setUint16(0, 0, Endian.little)); // Output Gain
    b.addByte(0); // Mapping Family
    return b.toBytes();
  }

  Uint8List _buildOpusTags() {
    const vendor = "gemini-opus-enc";
    final b = BytesBuilder();
    b.add("OpusTags".codeUnits);
    final vLen = Uint8List(4)..buffer.asByteData().setUint32(0, vendor.length, Endian.little);
    b.add(vLen);
    b.add(vendor.codeUnits);
    b.add([0, 0, 0, 0]); // User Comment List Length (0)
    return b.toBytes();
  }

  // --- Internal Splitter Logic ---

  Uint8List _peekBytes(int n) {
    final res = Uint8List(n);
    int count = 0;
    for (var chunk in _inputChunks) {
      int take = (n - count).clamp(0, chunk.length);
      res.setRange(count, count + take, chunk);
      count += take;
      if (count >= n) break;
    }
    return res;
  }

  Uint8List _readBytes(int n) {
    final res = Uint8List(n);
    int offset = 0;
    while (offset < n) {
      final first = _inputChunks.first;
      int take = (n - offset).clamp(0, first.length);
      res.setRange(offset, offset + take, first);
      offset += take;
      if (take == first.length) {
        _inputChunks.removeAt(0);
      } else {
        _inputChunks[0] = Uint8List.sublistView(first, take);
      }
    }
    _inputTotalLength -= n;
    return res;
  }

  void _consume(int n) {
    int remain = n;
    while (remain > 0 && _inputChunks.isNotEmpty) {
      final first = _inputChunks.first;
      if (first.length <= remain) {
        remain -= first.length;
        _inputChunks.removeAt(0);
      } else {
        _inputChunks[0] = Uint8List.sublistView(first, remain);
        remain = 0;
      }
    }
    _inputTotalLength -= n;
  }
}
