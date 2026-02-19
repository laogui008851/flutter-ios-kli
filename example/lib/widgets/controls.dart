import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:livekit_client/livekit_client.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';

import '../exts.dart';

class ControlsWidget extends StatefulWidget {
  //
  final Room room;
  final LocalParticipant participant;
  final ValueNotifier<List<dynamic>>? chatMessagesNotifier;
  final ValueChanged<String>? onChatSend;
  final VoidCallback? onChatOpen;

  const ControlsWidget(
    this.room,
    this.participant, {
    this.chatMessagesNotifier,
    this.onChatSend,
    this.onChatOpen,
    super.key,
  });

  @override
  State<StatefulWidget> createState() => _ControlsWidgetState();
}

class _ControlsWidgetState extends State<ControlsWidget> {
  //
  CameraPosition position = CameraPosition.front;

  List<MediaDevice>? _audioInputs;
  List<MediaDevice>? _audioOutputs;
  List<MediaDevice>? _videoInputs;

  StreamSubscription? _subscription;

  bool _speakerphoneOn = Hardware.instance.speakerOn ?? false;
  bool _popupMenuOpen = false;
  bool _needsRefresh = false;

  @override
  void initState() {
    super.initState();
    participant.addListener(_onChange);
    _subscription = Hardware.instance.onDeviceChange.stream.listen((List<MediaDevice> devices) {
      _loadDevices(devices);
    });
    unawaited(Hardware.instance.enumerateDevices().then(_loadDevices));
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    participant.removeListener(_onChange);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ControlsWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.participant != widget.participant) {
      oldWidget.participant.removeListener(_onChange);
      widget.participant.addListener(_onChange);
    }
  }

  LocalParticipant get participant => widget.participant;

  Widget _buildLabeledButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    Color? color,
  }) {
    return GestureDetector(
      onTap: onPressed,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color ?? Colors.white, size: 24),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: color ?? Colors.white70,
              fontSize: 10,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  void _loadDevices(List<MediaDevice> devices) async {
    _audioInputs = devices.where((d) => d.kind == 'audioinput').toList();
    _audioOutputs = devices.where((d) => d.kind == 'audiooutput').toList();
    _videoInputs = devices.where((d) => d.kind == 'videoinput').toList();
    if (_popupMenuOpen) {
      _needsRefresh = true;
      return;
    }
    setState(() {});
  }

  void _onChange() {
    // defer refresh while popup menu is open to avoid rendering glitches
    if (_popupMenuOpen) {
      _needsRefresh = true;
      return;
    }
    setState(() {});
  }

  void _unpublishAll() async {
    await participant.unpublishAllTracks();
  }

  bool get isMuted => participant.isMuted;

  void _disableAudio() async {
    await participant.setMicrophoneEnabled(false);
  }

  Future<void> _enableAudio() async {
    try {
      // 只在首次需要时请求权限，已经发布过音频则跳过
      if (lkPlatformIsMobile() && participant.audioTrackPublications.isEmpty) {
        final status = await Permission.microphone.request();
        if (!status.isGranted && !status.isLimited) {
          print('Microphone permission not granted: $status');
          if (mounted) {
            if (status.isPermanentlyDenied) {
              await context.showErrorDialog('麦克风权限已被拒绝，请到系统设置中开启');
              openAppSettings();
            } else {
              await context.showErrorDialog('需要麦克风权限才能开启音频');
            }
          }
          return;
        }
      }
      await participant.setMicrophoneEnabled(true);
    } catch (error) {
      print('could not enable microphone: $error');
      if (mounted) {
        await context.showErrorDialog(error);
      }
    }
  }

  void _disableVideo() async {
    await participant.setCameraEnabled(false);
  }

  void _enableVideo() async {
    try {
      // 只在首次需要时请求权限，已经在房间内发布过视频则跳过权限检查
      if (lkPlatformIsMobile() && participant.videoTrackPublications.isEmpty) {
        final status = await Permission.camera.request();
        if (!status.isGranted && !status.isLimited) {
          print('Camera permission not granted: $status');
          if (mounted) {
            if (status.isPermanentlyDenied) {
              await context.showErrorDialog('摄像头权限已被拒绝，请到系统设置中开启');
              openAppSettings();
            } else {
              await context.showErrorDialog('需要摄像头权限才能开启视频');
            }
          }
          return;
        }
      }
      await participant.setCameraEnabled(true);
    } catch (error) {
      print('could not enable camera: $error');
      if (mounted) {
        await context.showErrorDialog(error);
      }
    }
  }

  void _selectAudioOutput(MediaDevice device) async {
    await widget.room.setAudioOutputDevice(device);
    setState(() {});
  }

  void _selectAudioInput(MediaDevice device) async {
    await widget.room.setAudioInputDevice(device);
    setState(() {});
  }

  void _selectVideoInput(MediaDevice device) async {
    await widget.room.setVideoInputDevice(device);
    setState(() {});
  }

  void _setSpeakerphoneOn() async {
    _speakerphoneOn = !_speakerphoneOn;
    await widget.room.setSpeakerOn(_speakerphoneOn, forceSpeakerOutput: false);
    setState(() {});
  }

  void _toggleCamera() async {
    final track = participant.videoTrackPublications.firstOrNull?.track;
    if (track == null) return;

    try {
      final newPosition = position.switched();
      await track.setCameraPosition(newPosition);
      setState(() {
        position = newPosition;
      });
    } catch (error) {
      print('could not restart track: $error');
      return;
    }
  }

  void _enableScreenShare() async {
    if (lkPlatformIsDesktop()) {
      try {
        final source = await showDialog<DesktopCapturerSource>(
          context: context,
          builder: (context) => ScreenSelectDialog(),
        );
        if (source == null) {
          print('cancelled screenshare');
          return;
        }
        print('DesktopCapturerSource: ${source.id}');
        final track = await LocalVideoTrack.createScreenShareTrack(
          ScreenShareCaptureOptions(
            sourceId: source.id,
            maxFrameRate: 15.0,
          ),
        );
        await participant.publishVideoTrack(track);
      } catch (e) {
        print('could not publish video: $e');
      }
      return;
    }
    if (lkPlatformIs(PlatformType.android)) {
      final permissionOk = await _ensureAndroidForegroundPermissions();
      if (!permissionOk) return;

      // Android specific
      final hasCapturePermission = await Helper.requestCapturePermission();
      if (!hasCapturePermission) {
        return;
      }

      final backgroundOk = await _enableAndroidBackgroundExecution();
      if (!backgroundOk) {
        if (!mounted) return;
        await context.showErrorDialog('需要启用前台服务/通知权限以进行屏幕共享');
        return;
      }
    }

    if (lkPlatformIsWebMobile()) {
      if (!mounted) return;
      await context.showErrorDialog('Screen share is not supported on mobile web');
      return;
    }
    try {
      await participant.setScreenShareEnabled(true, captureScreenAudio: true);
    } catch (e) {
      print('could not enable screen share: $e');
      if (!mounted) return;
      await context.showErrorDialog('屏幕共享启动失败: $e');
    }
  }

  void _disableScreenShare() async {
    await participant.setScreenShareEnabled(false);
    if (lkPlatformIs(PlatformType.android)) {
      // Android specific
      try {
        await _disableAndroidBackgroundExecution();
      } catch (error) {
        print('error disabling screen share: $error');
      }
    }
  }

  Future<bool> _ensureAndroidForegroundPermissions() async {
    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      print('Microphone permission not granted');
      return false;
    }
    final notificationStatus = await Permission.notification.request();
    if (!notificationStatus.isGranted) {
      print('Notification permission not granted');
      return false;
    }
    return true;
  }

  Future<bool> _enableAndroidBackgroundExecution() async {
    try {
      const androidConfig = FlutterBackgroundAndroidConfig(
        notificationTitle: '屏幕共享',
        notificationText: '云际会议正在共享屏幕',
        notificationImportance: AndroidNotificationImportance.normal,
        notificationIcon: AndroidResource(name: 'livekit_ic_launcher', defType: 'mipmap'),
      );
      final hasPermissions = await FlutterBackground.initialize(androidConfig: androidConfig);
      if (!hasPermissions) {
        print('FlutterBackground permissions not granted');
        return false;
      }
      if (!FlutterBackground.isBackgroundExecutionEnabled) {
        await FlutterBackground.enableBackgroundExecution();
      }
      return FlutterBackground.isBackgroundExecutionEnabled;
    } catch (e) {
      print('could not enable background execution: $e');
      return false;
    }
  }

  Future<void> _disableAndroidBackgroundExecution() async {
    if (FlutterBackground.isBackgroundExecutionEnabled) {
      await FlutterBackground.disableBackgroundExecution();
    }
  }

  void _onTapDisconnect() async {
    final result = await context.showDisconnectDialog();
    if (result == true) await widget.room.disconnect();
  }

  void _onTapSendData() {
    if (widget.onChatOpen != null) {
      widget.onChatOpen!();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: 15,
        horizontal: 15,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // 🎤 麦克风开关
          if (participant.isMicrophoneEnabled())
            _buildLabeledButton(
              icon: Icons.mic,
              label: '麦克风',
              onPressed: _disableAudio,
            )
          else
            _buildLabeledButton(
              icon: Icons.mic_off,
              label: '麦克风',
              onPressed: _enableAudio,
            ),
          // 🔇 扬声器/静音
          if (!kIsWeb && lkPlatformIsMobile())
            _buildLabeledButton(
              icon: _speakerphoneOn ? Icons.volume_up : Icons.volume_off,
              label: '扬声器',
              onPressed: _setSpeakerphoneOn,
            ),
          // 📹 摄像头开关
          if (participant.isCameraEnabled())
            _buildLabeledButton(
              icon: Icons.videocam,
              label: '摄像头',
              onPressed: _disableVideo,
            )
          else
            _buildLabeledButton(
              icon: Icons.videocam_off,
              label: '摄像头',
              onPressed: _enableVideo,
            ),
          // 📤 屏幕共享
          if (participant.isScreenShareEnabled())
            _buildLabeledButton(
              icon: Icons.stop_screen_share,
              label: '共享',
              onPressed: () => _disableScreenShare(),
            )
          else
            _buildLabeledButton(
              icon: Icons.screen_share,
              label: '共享',
              onPressed: () => _enableScreenShare(),
            ),
          // 💬 聊天消息
          _buildLabeledButton(
            icon: Icons.chat,
            label: '消息',
            onPressed: _onTapSendData,
          ),
          // ✕ 关闭/退出
          _buildLabeledButton(
            icon: Icons.call_end,
            label: '挂断',
            onPressed: _onTapDisconnect,
            color: Colors.red,
          ),
          // 更多选项（折叠）
          PopupMenuButton<String>(
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.more_vert, size: 24),
            tooltip: '更多选项',
            onOpened: () {
              _popupMenuOpen = true;
            },
            onCanceled: () {
              _popupMenuOpen = false;
              if (_needsRefresh) {
                _needsRefresh = false;
                setState(() {});
              }
            },
            onSelected: (_) {
              _popupMenuOpen = false;
              if (_needsRefresh) {
                _needsRefresh = false;
                setState(() {});
              }
            },
            itemBuilder: (BuildContext context) {
              return [
                // 切换前后摄像头
                PopupMenuItem<String>(
                  value: 'toggle_camera',
                  onTap: _toggleCamera,
                  child: ListTile(
                    leading: Icon(
                      position == CameraPosition.back ? Icons.video_camera_front : Icons.video_camera_back,
                      color: Colors.white,
                    ),
                    title: Text(position == CameraPosition.back ? '切换前置摄像头' : '切换后置摄像头'),
                  ),
                ),
                // 选择音频输入
                if (_audioInputs != null && _audioInputs!.isNotEmpty)
                  PopupMenuItem<String>(
                    value: 'audio_input',
                    child: ListTile(
                      leading: const Icon(Icons.settings_voice, color: Colors.white),
                      title: const Text('选择麦克风'),
                      subtitle: Text(
                        _audioInputs!
                                .firstWhereOrNull((d) => d.deviceId == widget.room.selectedAudioInputDeviceId)
                                ?.label ??
                            '默认',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                // 选择音频输出
                if (!lkPlatformIsMobile() && _audioOutputs != null && _audioOutputs!.isNotEmpty)
                  PopupMenuItem<String>(
                    value: 'audio_output',
                    child: ListTile(
                      leading: const Icon(Icons.speaker, color: Colors.white),
                      title: const Text('选择扬声器'),
                      subtitle: Text(
                        _audioOutputs!
                                .firstWhereOrNull((d) => d.deviceId == widget.room.selectedAudioOutputDeviceId)
                                ?.label ??
                            '默认',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                // 选择摄像头
                if (_videoInputs != null && _videoInputs!.isNotEmpty)
                  PopupMenuItem<String>(
                    value: 'video_input',
                    child: ListTile(
                      leading: const Icon(Icons.videocam, color: Colors.white),
                      title: const Text('选择摄像头'),
                      subtitle: Text(
                        _videoInputs!
                                .firstWhereOrNull((d) => d.deviceId == widget.room.selectedVideoInputDeviceId)
                                ?.label ??
                            '默认',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
              ];
            },
          ),
        ],
      ),
    );
  }
}
