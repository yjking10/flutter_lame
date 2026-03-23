import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_lame_example/opus_to_mp3_streaming.dart' hide StreamingOpusToMp3;
import 'package:flutter_lame_example/test_pcm_to_ogg_page.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:flutter_lame/flutter_lame.dart';
import 'package:wav/wav.dart';

import 'streaming_opus_to_mp3.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p; // 建议添加 path 库方便处理路径
import 'package:flutter/foundation.dart' show kIsWeb, Float32List;
import 'package:flutter/material.dart';


class FileStorageHelper {
  /// 获取临时沙盒路径（适合转换后的中间产物）
  static Future<String> getTempSavePath(String fileName) async {
    final directory = await getTemporaryDirectory();
    return p.join(directory.path, fileName);
  }

  /// 获取文档沙盒路径（适合最终保存的音频文件）
  static Future<String> getDocumentSavePath(String fileName) async {
    final directory = await getApplicationDocumentsDirectory();
    return p.join(directory.path, fileName);
  }
}
void main() async{
  WidgetsFlutterBinding.ensureInitialized();
  initOpus(await opus_flutter.load());
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {

    return MaterialApp(
      home: Home(),
    );
  }
}

class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  String? inputPath;
  String outputName = "output.mp3";
  bool working = false;

  void selectInputFile() async {
    final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        dialogTitle: "Select WAV file",
        allowedExtensions: ["wav"],
        allowMultiple: false);

    if (result == null) {
      return;
    }

    if (result.paths.isEmpty) {
      return;
    }

    setState(() {
      inputPath = result.paths[0];
    });
  }

  void selectInputOpusFile() async {

    // final result = await FilePicker.platform.pickFiles(
    //     type: FileType.custom,
    //     dialogTitle: "Select Opus file",
    //     allowedExtensions: ["opus"],
    //     allowMultiple: false);
    //
    // if (result == null) {
    //   return;
    // }
    //
    // if (result.paths.isEmpty) {
    //   return;
    // }
    //
    // String outputMp3Path = result.paths[0]!;


  }

  Stream<List<int>> _getAssetStream(String path) async* {
    final ByteData data = await rootBundle.load(path);
    final buffer = data.buffer.asUint8List();

    const int chunkSize = 4096; // 每次读取 4KB
    for (int i = 0; i < buffer.length; i += chunkSize) {
      int end = (i + chunkSize < buffer.length) ? i + chunkSize : buffer.length;
      yield buffer.sublist(i, end);
    }
  }

  void selectInputOpusFileStreaming() async {

    // final result = await FilePicker.platform.pickFiles(
    //     type: FileType.custom,
    //     dialogTitle: "Select Opus file",
    //     allowedExtensions: ["opus"],
    //     allowMultiple: false);
    //
    // if (result == null) {
    //   return;
    // }
    //
    // if (result.paths.isEmpty) {
    //   return;
    // }
    //
    // String outputMp3Path = result.paths[0]!;

//     final String outputMp3Path = await FileStorageHelper.getTempSavePath("002256772213.mp3");
//     final file = File(outputMp3Path);
//     if (file.existsSync()) file.deleteSync();
//
//     IOSink sink = file.openWrite();
//
//     final converter = StreamingOpusToMp3(
//     );
//
//     final opusByteData = await rootBundle.load('assets/audio/002256772213.opus');
//
//     // 假设你有一个完整的 length-prefixed Opus 数据块
//
// // 监听 MP3 输出
//     converter.mp3Stream.listen((Uint8List mp3Chunk) {
//       // 发送到网络、保存内存、播放等
//       print('Got MP3 chunk of ${mp3Chunk.length} bytes');
//       sink.add(mp3Chunk);
//     });
//
// // 启动转换
//     await converter.process(Stream.value(opusByteData.buffer.asUint8List()));
//
//     print('opus---> mp3 finish');

    // await converter.finish();
  }



  void encodeMp3() async {
    if (inputPath == null) {
      throw StateError("inputPath should not be null");
    }

    final outputDir = await FilePicker.platform.getDirectoryPath(
        dialogTitle: "Pick a directory to save output MP3 file");
    if (outputDir == null) {
      return;
    }

    setState(() {
      working = true;
    });

    LameMp3Encoder? encoder;
    IOSink? sink;
    try {
      final wav = await compute(Wav.readFile, inputPath!);

      final File f = File(path.join(outputDir, outputName));
      sink = f.openWrite();
      encoder = LameMp3Encoder(
          sampleRate: wav.samplesPerSecond, numChannels: wav.channels.length);

      final left = wav.channels[0];
      Float64List? right;
      if (wav.channels.length > 1) {
        right = wav.channels[1];
      }

      for (int i = 0; i < left.length; i += wav.samplesPerSecond) {
        final mp3Frame = await encoder.encodeDouble(
            leftChannel: left.sublist(i, i + wav.samplesPerSecond),
            rightChannel: right?.sublist(i, i + wav.samplesPerSecond));
        sink.add(mp3Frame);
      }
      sink.add(await encoder.flush());
    } catch (e) {
      showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text("Error"),
            content: Text(e.toString()),
          ));
    } finally {
      encoder?.close();
      sink?.close();
      setState(() {
        working = false;
      });
    }
  }
  @override
  Widget build(BuildContext context) {
    const textStyle = TextStyle(fontSize: 25);
    const spacerSmall = SizedBox(height: 10);
    const spacerLarge = SizedBox(height: 30);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Flutter LAME Example'),
      ),
      body: SingleChildScrollView(
        child: Container(
          padding: const EdgeInsets.all(10),
          child: Column(
            children: [
              const Text(
                'Call LAME API through FFI that is shipped as source in the package. '
                    'The native code is built as part of the Flutter Runner build.',
                style: textStyle,
                textAlign: TextAlign.center,
              ),
              const Divider(),
              spacerLarge,

              ElevatedButton(
                  onPressed: (){
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => TestPcmToOggPage()),
                    );
                  },
                  child: const Text(
                    " Opus 2 ogg",
                    style: textStyle,
                  )),


              ElevatedButton(
                  onPressed: !working ? selectInputOpusFileStreaming : null,
                  child: const Text(
                    "Select Opus file Streaming",
                    style: textStyle,
                  )),
              ElevatedButton(
                  onPressed: !working ? selectInputOpusFile : null,
                  child: const Text(
                    "Select Opus file",
                    style: textStyle,
                  )),
              ElevatedButton(
                  onPressed: !working ? selectInputFile : null,
                  child: const Text(
                    "Select WAV file",
                    style: textStyle,
                  )),
              spacerSmall,
              RichText(
                text: TextSpan(
                    style: const TextStyle(fontSize: 25, color: Colors.black),
                    children: [
                      const TextSpan(
                          text: "Input WAV file: ",
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      TextSpan(text: inputPath)
                    ]),
                textAlign: TextAlign.center,
              ),
              spacerSmall,
              TextFormField(
                  onChanged: (v) => setState(() {
                    outputName = v;
                  }),
                  decoration:
                  const InputDecoration(labelText: "Output MP3 filename"),
                  initialValue: outputName),
              spacerSmall,
              ElevatedButton(
                  onPressed:
                  inputPath != null && outputName.isNotEmpty && !working
                      ? encodeMp3
                      : null,
                  child: const Text(
                    "Encode to MP3",
                    style: textStyle,
                  )),
              spacerSmall,
              if (working) const CircularProgressIndicator(),
            ],
          ),
        ),
      ),
    );
  }
}

