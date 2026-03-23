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


class StreamOpusToOgg {
  final int sampleRate;
  final int channels;
  final int packetsPerPage;

  final StreamController<Uint8List> _controller = StreamController.broadcast();
  Stream<Uint8List> get stream => _controller.stream;

  final OggPageBuilder _ogg = OggPageBuilder();
  final List<Uint8List> _packetBuffer = [];
  int _granulePos = 0;
  bool _headerSent = false;

  StreamOpusToOgg({
    this.sampleRate = 16000,
    this.channels = 1,
    this.packetsPerPage = 10,
  });

  // 假设 40 字节对应 20ms 的 Opus 帧
  // 在 OggOpus 中，Granule Position 始终基于 48kHz 采样率计算
  int get _step48k => (48000 * 0.02).toInt(); // 960

  void addOpus(Uint8List packet) {
    if (!_headerSent) {
      _sendHeaders();
      _headerSent = true;
    }

    _packetBuffer.add(packet);

    if (_packetBuffer.length >= packetsPerPage) {
      _flushPage(isLast: false);
    }
  }

  void _flushPage({bool isLast = false}) {
    if (_packetBuffer.isEmpty && !isLast) return;

    // 更新时间戳
    _granulePos += _step48k * _packetBuffer.length;

    final page = _ogg.buildPage(
      packets: List.from(_packetBuffer),
      granulePos: _granulePos,
      headerType: isLast ? 0x04 : 0x00, // 0x04 为 End of Stream
    );

    _controller.add(page);
    _packetBuffer.clear();
  }

  void _sendHeaders() {
    // Page 1: ID Header (BOS)
    _controller.add(_ogg.buildPage(
      packets: [_buildOpusHead()],
      granulePos: 0,
      headerType: 0x02, // Beginning of Stream
    ));

    // Page 2: Comment Header
    _controller.add(_ogg.buildPage(
      packets: [_buildOpusTags()],
      granulePos: 0,
      headerType: 0x00,
    ));
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

  Future<void> close() async {
    _flushPage(isLast: true);
    await Future.delayed(const Duration(milliseconds: 50));
    await _controller.close();
  }
}

class OpusPacketSplitterBE32 {
  final List<Uint8List> _chunks = [];
  int _totalLength = 0;
  final StreamController<Uint8List> _controller = StreamController.broadcast();
  Stream<Uint8List> get stream => _controller.stream;

  void add(Uint8List data) {
    if (data.isEmpty) return;
    _chunks.add(data);
    _totalLength += data.length;
    _process();
  }

  void _process() {
    while (_totalLength >= 4) {
      // 1. 读取 4 字节长度头 (Big Endian)
      final header = _peekBytes(4);
      final packetLen = (header[0] << 24) | (header[1] << 16) | (header[2] << 8) | header[3];

      if (packetLen <= 0 || packetLen > 65535) {
        _chunks.clear();
        _totalLength = 0;
        return;
      }

      if (_totalLength < 4 + packetLen) break;

      // 2. 消耗头
      _consume(4);
      // 3. 提取 Packet
      final packet = _readBytes(packetLen);
      _controller.add(packet);
    }
  }

  Uint8List _peekBytes(int n) {
    final res = Uint8List(n);
    int count = 0;
    for (var chunk in _chunks) {
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
      final first = _chunks.first;
      int take = (n - offset).clamp(0, first.length);
      res.setRange(offset, offset + take, first);
      offset += take;
      if (take == first.length) {
        _chunks.removeAt(0);
      } else {
        _chunks[0] = Uint8List.sublistView(first, take);
      }
    }
    _totalLength -= n;
    return res;
  }

  void _consume(int n) {
    int remain = n;
    while (remain > 0 && _chunks.isNotEmpty) {
      final first = _chunks.first;
      if (first.length <= remain) {
        remain -= first.length;
        _chunks.removeAt(0);
      } else {
        _chunks[0] = Uint8List.sublistView(first, remain);
        remain = 0;
      }
    }
    _totalLength -= n;
  }

  void close() => _controller.close();
}