import 'package:flutter/material.dart';

import 'opus_stream_sender.dart';

class TestPcmToOggPage extends StatefulWidget {
  const TestPcmToOggPage({super.key});

  @override
  State<TestPcmToOggPage> createState() => _TestPcmToOggPageState();
}

class _TestPcmToOggPageState extends State<TestPcmToOggPage> {
  late final _sender = OpusStreamSender();

  _test() async {
// 开始
    await _sender.startSending();

  }

  _stopTest() async {
    _sender.stop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Flutter LAME Example'),
      ),
      body: Column(
        children: [
          ElevatedButton(
              onPressed: () {
                _test();
              },
              child: Text('Start Test')),
          ElevatedButton(
              onPressed: () {
                _stopTest();
              },
              child: Text('Stop Test'))
        ],
      ),
    );
  }
}
