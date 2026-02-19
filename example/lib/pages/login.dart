import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart';
import 'package:livekit_example/widgets/text_field.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';

import 'room.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _sandboxIdCtrl = TextEditingController();
  final _nicknameCtrl = TextEditingController();
  final _roomNameCtrl = TextEditingController();
  bool _busy = false;
  String? _errorMessage;

  // 环境变量配置（编译时注入）
  static const _envSandboxId = String.fromEnvironment('SANDBOX_ID');
  static const _envRoomName = String.fromEnvironment('ROOM_NAME');
  static const _envNickname = String.fromEnvironment('NICKNAME');
  // Token Server 地址（Vercel 上的 Meet API）
  static const _tokenServerUrl = String.fromEnvironment(
    'TOKEN_SERVER_URL',
    defaultValue: 'https://meet.jshx.club',
  );

  @override
  void initState() {
    super.initState();
    _loadSavedData();
  }

  Future<void> _loadSavedData() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      // 优先使用环境变量，其次使用保存的值
      _sandboxIdCtrl.text = _envSandboxId.isNotEmpty ? _envSandboxId : (prefs.getString('sandboxId') ?? '');
      _nicknameCtrl.text = _envNickname.isNotEmpty ? _envNickname : (prefs.getString('nickname') ?? '');
      _roomNameCtrl.text = _envRoomName.isNotEmpty ? _envRoomName : (prefs.getString('roomName') ?? '');
    });
  }

  @override
  void dispose() {
    _sandboxIdCtrl.dispose();
    _nicknameCtrl.dispose();
    _roomNameCtrl.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final authCode = _sandboxIdCtrl.text.trim();
    final nickname = _nicknameCtrl.text.trim();
    final roomName = _roomNameCtrl.text.trim().isNotEmpty ? _roomNameCtrl.text.trim() : '默认房间';

    // 验证授权码
    if (authCode.isEmpty) {
      setState(() {
        _errorMessage = '请输入授权码';
      });
      return;
    }

    setState(() {
      _busy = true;
      _errorMessage = null;
    });

    try {
      // 请求权限（移动端）
      if (lkPlatformIsMobile()) {
        await Permission.camera.request();
        await Permission.microphone.request();
        if (lkPlatformIs(PlatformType.android)) {
          await Permission.bluetooth.request();
          await Permission.bluetoothConnect.request();
        }
      }

      // 保存输入内容
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('sandboxId', authCode);
      await prefs.setString('nickname', nickname);
      await prefs.setString('roomName', roomName);

      final displayName = nickname.isNotEmpty ? nickname : '用户${DateTime.now().millisecondsSinceEpoch % 10000}';

      // 调用 Token Server 验证授权码并获取 LiveKit Token
      final uri = Uri.parse('$_tokenServerUrl/api/connection-details').replace(
        queryParameters: {
          'roomName': roomName,
          'participantName': displayName,
          'authCode': authCode,
        },
      );

      final httpResponse = await http.get(uri);
      if (httpResponse.statusCode < 200 || httpResponse.statusCode >= 300) {
        String errorMsg = '授权码验证失败';
        try {
          final errData = jsonDecode(httpResponse.body) as Map<String, dynamic>;
          errorMsg = (errData['error'] as String?) ?? errorMsg;
        } catch (_) {}
        throw Exception(errorMsg);
      }

      final tokenData = jsonDecode(httpResponse.body) as Map<String, dynamic>;
      final serverUrl = tokenData['serverUrl'] as String;
      final participantToken = tokenData['participantToken'] as String;

      if (!mounted) return;

      // 直接创建房间并连接，跳过预览页
      final room = Room(
        roomOptions: const RoomOptions(
          adaptiveStream: true,
          dynacast: true,
          defaultAudioPublishOptions: AudioPublishOptions(
            name: 'audio',
          ),
          defaultCameraCaptureOptions: CameraCaptureOptions(
            maxFrameRate: 24,
            params: VideoParameters(
              dimensions: VideoDimensions(640, 480),
            ),
          ),
          defaultScreenShareCaptureOptions: ScreenShareCaptureOptions(
            useiOSBroadcastExtension: true,
            params: VideoParameters(
              dimensions: VideoDimensionsPresets.h720_169,
            ),
          ),
          defaultVideoPublishOptions: VideoPublishOptions(
            simulcast: false,
            videoCodec: 'VP8',
            videoEncoding: VideoEncoding(
              maxBitrate: 1500 * 1000,
              maxFramerate: 24,
            ),
            screenShareEncoding: VideoEncoding(
              maxBitrate: 2000 * 1000,
              maxFramerate: 15,
            ),
          ),
        ),
      );

      final listener = room.createListener();

      // 直接连接到 LiveKit 服务器
      await room.connect(serverUrl, participantToken);

      // 连接成功后再开启摄像头和麦克风（不阻塞进房间）
      unawaited(Future.wait([
        room.localParticipant?.setMicrophoneEnabled(true) ?? Future.value(),
        room.localParticipant?.setCameraEnabled(true) ?? Future.value(),
      ]).catchError((_) => <void>[]));

      if (!mounted) return;

      // 进入房间页面，传入 authCode 用于离开时释放
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => RoomPage(
            room,
            listener,
            authCode: authCode,
            tokenServerUrl: _tokenServerUrl,
          ),
        ),
      );
    } catch (e) {
      setState(() {
        _errorMessage = '连接失败: $e';
      });
    } finally {
      setState(() {
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        alignment: Alignment.center,
        child: SingleChildScrollView(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Logo
                Image.asset(
                  'images/removebgpin.png',
                  width: 100,
                  height: 100,
                ),
                const SizedBox(height: 20),
                const Text(
                  '云际会议',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 40),

                // 授权码输入
                LKTextField(
                  label: '授权码',
                  ctrl: _sandboxIdCtrl,
                  hintText: '请输入授权码',
                ),
                const SizedBox(height: 20),

                // 昵称输入
                LKTextField(
                  label: '昵称',
                  ctrl: _nicknameCtrl,
                  hintText: '显示在房间中的名字',
                ),
                const SizedBox(height: 20),

                // 房间名称输入
                LKTextField(
                  label: '房间名称',
                  ctrl: _roomNameCtrl,
                  hintText: '默认房间',
                ),
                const SizedBox(height: 10),

                // 错误提示
                if (_errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(
                        color: Colors.red,
                        fontSize: 14,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                const SizedBox(height: 30),

                // 加入按钮
                ElevatedButton(
                  onPressed: _busy ? null : _join,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text(
                          '加入房间',
                          style: TextStyle(fontSize: 18),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
