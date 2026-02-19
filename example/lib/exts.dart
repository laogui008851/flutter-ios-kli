import 'package:flutter/material.dart';

extension LKExampleExt on BuildContext {
  //
  Future<bool?> showPlayAudioManuallyDialog() => showDialog<bool>(
        context: this,
        builder: (ctx) => AlertDialog(
          title: const Text('播放音频'),
          content: const Text('iOS Safari 需要手动激活音频播放！'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('忽略'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('播放'),
            ),
          ],
        ),
      );

  Future<void> showErrorDialog(dynamic exception) => showDialog<void>(
        context: this,
        builder: (ctx) => AlertDialog(
          title: const Text('错误'),
          content: Text(exception.toString()),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('确定'),
            )
          ],
        ),
      );

  Future<bool?> showDisconnectDialog() => showDialog<bool>(
        context: this,
        builder: (ctx) => AlertDialog(
          title: const Text('退出房间'),
          content: const Text('确定要退出房间吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('退出'),
            ),
          ],
        ),
      );

  Future<bool?> showRecordingStatusChangedDialog(bool isActiveRecording) => showDialog<bool>(
        context: this,
        builder: (ctx) => AlertDialog(
          title: const Text('录制提醒'),
          content: Text(isActiveRecording ? '房间正在录制中' : '房间录制已停止'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确定'),
            ),
          ],
        ),
      );
}
