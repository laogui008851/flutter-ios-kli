import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart';

import '../exts.dart';
import '../utils.dart';
import '../widgets/chat.dart';
import '../widgets/controls.dart';
import '../widgets/participant.dart';
import '../widgets/participant_info.dart';

class RoomPage extends StatefulWidget {
  final Room room;
  final EventsListener<RoomEvent> listener;
  final String? authCode;
  final String? tokenServerUrl;

  const RoomPage(
    this.room,
    this.listener, {
    this.authCode,
    this.tokenServerUrl,
    super.key,
  });

  @override
  State<StatefulWidget> createState() => _RoomPageState();
}

class _RoomPageState extends State<RoomPage> with WidgetsBindingObserver {
  List<ParticipantTrack> participantTracks = [];
  final ValueNotifier<List<LocalChatMessage>> _chatMessagesNotifier = ValueNotifier([]);
  bool _isDisconnecting = false;
  EventsListener<RoomEvent> get _listener => widget.listener;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // add callback for a `RoomEvent` as opposed to a `ParticipantEvent`
    widget.room.addListener(_onRoomDidUpdate);
    // add callbacks for finer grained events
    _setUpListeners();
    _sortParticipants();
    // 不再弹出发布确认对话框，由 login 页直接启用摄像头和麦克风

    if (lkPlatformIs(PlatformType.android)) {
      unawaited(Hardware.instance.setSpeakerphoneOn(true));
    }

    if (lkPlatformIsDesktop()) {
      onWindowShouldClose = () async {
        unawaited(widget.room.disconnect());
        await _listener.waitFor<RoomDisconnectedEvent>(duration: const Duration(seconds: 5));
      };
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // App 被系统杀掉或切到后台时主动断开连接
    if (state == AppLifecycleState.detached) {
      _safeDisconnect();
    }
  }

  Future<void> _safeDisconnect() async {
    if (_isDisconnecting) return;
    _isDisconnecting = true;
    try {
      await widget.room.disconnect();
      // 通知 Token Server 释放授权码
      await _releaseAuthCode();
    } catch (e) {
      print('Error disconnecting: $e');
    }
  }

  /// 通知服务器释放授权码使用状态
  Future<void> _releaseAuthCode() async {
    final authCode = widget.authCode;
    final serverUrl = widget.tokenServerUrl;
    if (authCode == null || authCode.isEmpty || serverUrl == null) return;
    try {
      final uri = Uri.parse('$serverUrl/api/leave').replace(
        queryParameters: {'authCode': authCode},
      );
      await http.get(uri).timeout(const Duration(seconds: 5));
    } catch (e) {
      print('释放授权码失败: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // always dispose listener
    widget.room.removeListener(_onRoomDidUpdate);
    // 确保断开连接后再 dispose
    unawaited(_disposeRoomAsync());
    onWindowShouldClose = null;
    super.dispose();
  }

  Future<void> _disposeRoomAsync() async {
    await _safeDisconnect();
    await _listener.dispose();
    await widget.room.dispose();
    _chatMessagesNotifier.dispose();
  }

  /// for more information, see [event types](https://docs.livekit.io/client/events/#events)
  void _setUpListeners() => _listener
    ..on<RoomDisconnectedEvent>((event) async {
      if (event.reason != null) {
        print('Room disconnected: reason => ${event.reason}');
      }
      WidgetsBindingCompatible.instance
          ?.addPostFrameCallback((timeStamp) => Navigator.popUntil(context, (route) => route.isFirst));
    })
    ..on<ParticipantEvent>((event) {
      // sort participants on many track events as noted in documentation linked above
      _sortParticipants();
    })
    ..on<RoomRecordingStatusChanged>((event) {
      unawaited(context.showRecordingStatusChangedDialog(event.activeRecording));
    })
    ..on<RoomAttemptReconnectEvent>((event) {
      print('Attempting to reconnect ${event.attempt}/${event.maxAttemptsRetry}, '
          '(${event.nextRetryDelaysInMs}ms delay until next attempt)');
    })
    ..on<LocalTrackSubscribedEvent>((event) {
      print('Local track subscribed: ${event.trackSid}');
    })
    ..on<LocalTrackPublishedEvent>((_) => _sortParticipants())
    ..on<LocalTrackUnpublishedEvent>((_) => _sortParticipants())
    ..on<TrackSubscribedEvent>((_) => _sortParticipants())
    ..on<TrackUnsubscribedEvent>((_) => _sortParticipants())
    ..on<ParticipantNameUpdatedEvent>((event) {
      print('Participant name updated: ${event.participant.identity}, name => ${event.name}');
      _sortParticipants();
    })
    ..on<ParticipantMetadataUpdatedEvent>((event) {
      print('Participant metadata updated: ${event.participant.identity}, metadata => ${event.metadata}');
    })
    ..on<RoomMetadataChangedEvent>((event) {
      print('Room metadata changed: ${event.metadata}');
    })
    ..on<DataReceivedEvent>((event) {
      String decoded = 'Failed to decode';
      try {
        decoded = utf8.decode(event.data);
      } catch (err) {
        print('Failed to decode: $err');
      }
      _chatMessagesNotifier.value = [
        ..._chatMessagesNotifier.value,
        LocalChatMessage(
          senderName: event.participant?.name ?? event.participant?.identity ?? '未知',
          senderIdentity: event.participant?.identity ?? '',
          content: decoded,
          timestamp: DateTime.now(),
          isLocal: false,
        ),
      ];
    })
    ..on<AudioPlaybackStatusChanged>((event) async {
      if (!widget.room.canPlaybackAudio) {
        print('Audio playback failed for iOS Safari ..........');
        final yesno = await context.showPlayAudioManuallyDialog();
        if (yesno == true) {
          await widget.room.startAudio();
        }
      }
    });

  void _sendChatMessage(String text) async {
    _chatMessagesNotifier.value = [
      ..._chatMessagesNotifier.value,
      LocalChatMessage(
        senderName: widget.room.localParticipant?.name ?? '我',
        senderIdentity: widget.room.localParticipant?.identity ?? '',
        content: text,
        timestamp: DateTime.now(),
        isLocal: true,
      ),
    ];
    unawaited(widget.room.localParticipant?.publishData(
      utf8.encode(text),
      reliable: true,
    ));
  }

  void _showChatPanel() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black26,
      builder: (_) => ChatPanel(
        room: widget.room,
        messagesNotifier: _chatMessagesNotifier,
        onSend: _sendChatMessage,
      ),
    );
  }

  void _onRoomDidUpdate() {
    _sortParticipants();
  }

  void _sortParticipants() {
    final userMediaTracks = <ParticipantTrack>[];
    final screenTracks = <ParticipantTrack>[];
    for (var participant in widget.room.remoteParticipants.values) {
      for (var t in participant.videoTrackPublications) {
        if (t.isScreenShare) {
          screenTracks.add(ParticipantTrack(
            participant: participant,
            type: ParticipantTrackType.kScreenShare,
          ));
        } else {
          userMediaTracks.add(ParticipantTrack(participant: participant));
        }
      }
    }
    // sort speakers for the grid
    userMediaTracks.sort((a, b) {
      // loudest speaker first
      if (a.participant.isSpeaking && b.participant.isSpeaking) {
        if (a.participant.audioLevel > b.participant.audioLevel) {
          return -1;
        } else {
          return 1;
        }
      }

      // last spoken at
      final aSpokeAt = a.participant.lastSpokeAt?.millisecondsSinceEpoch ?? 0;
      final bSpokeAt = b.participant.lastSpokeAt?.millisecondsSinceEpoch ?? 0;

      if (aSpokeAt != bSpokeAt) {
        return aSpokeAt > bSpokeAt ? -1 : 1;
      }

      // video on
      if (a.participant.hasVideo != b.participant.hasVideo) {
        return a.participant.hasVideo ? -1 : 1;
      }

      // joinedAt
      return a.participant.joinedAt.millisecondsSinceEpoch - b.participant.joinedAt.millisecondsSinceEpoch;
    });

    final localParticipantTracks = widget.room.localParticipant?.videoTrackPublications;
    if (localParticipantTracks != null) {
      for (var t in localParticipantTracks) {
        if (t.isScreenShare) {
          screenTracks.add(ParticipantTrack(
            participant: widget.room.localParticipant!,
            type: ParticipantTrackType.kScreenShare,
          ));
        } else {
          userMediaTracks.add(ParticipantTrack(participant: widget.room.localParticipant!));
        }
      }
    }
    setState(() {
      participantTracks = [...screenTracks, ...userMediaTracks];
    });
  }

  /// 获取所有参与者（本地 + 远程）
  List<Participant> get _allParticipants {
    final list = <Participant>[];
    if (widget.room.localParticipant != null) {
      list.add(widget.room.localParticipant!);
    }
    list.addAll(widget.room.remoteParticipants.values);
    return list;
  }

  /// 构建底部参与者列表栏
  Widget _buildParticipantBar() {
    final participants = _allParticipants;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Colors.black.withValues(alpha: 0.5),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '参会人员 (${participants.length})',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: participants.map((p) {
              final isLocal = p is LocalParticipant;
              final name = p.name.isNotEmpty ? p.name : (p.identity.isNotEmpty ? p.identity : '未知');
              final isSpeaking = p.isSpeaking;
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: isSpeaking ? Colors.green.withValues(alpha: 0.3) : Colors.white.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(16),
                  border: isSpeaking ? Border.all(color: Colors.greenAccent, width: 1.5) : null,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      p.hasAudio ? Icons.mic : Icons.mic_off,
                      color: p.hasAudio ? Colors.greenAccent : Colors.redAccent,
                      size: 14,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      isLocal ? '$name (我)' : name,
                      style: TextStyle(
                        color: isLocal ? Colors.cyanAccent : Colors.white,
                        fontSize: 13,
                        fontWeight: isLocal ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                    if (p.hasVideo) ...[
                      const SizedBox(width: 4),
                      const Icon(Icons.videocam, color: Colors.white54, size: 14),
                    ],
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          // 按返回键时先断开连接再退出
          await _safeDisconnect();
          if (mounted) {
            Navigator.of(context).pop();
          }
        },
        child: Scaffold(
          body: Stack(
            children: [
              Column(
                children: [
                  Expanded(
                      child: participantTracks.isNotEmpty
                          ? ParticipantWidget.widgetFor(participantTracks.first, showStatsLayer: false)
                          : Container()),
                  // 参与者列表栏
                  _buildParticipantBar(),
                  if (widget.room.localParticipant != null)
                    SafeArea(
                      top: false,
                      child: ControlsWidget(
                        widget.room,
                        widget.room.localParticipant!,
                        chatMessagesNotifier: _chatMessagesNotifier,
                        onChatSend: _sendChatMessage,
                        onChatOpen: _showChatPanel,
                      ),
                    )
                ],
              ),
              Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: SafeArea(
                    bottom: false,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      color: Colors.black.withValues(alpha: 0.4),
                      child: Row(
                        children: [
                          const Icon(Icons.meeting_room, color: Colors.white70, size: 18),
                          const SizedBox(width: 6),
                          Text(
                            widget.room.name ?? '未知房间',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )),
              // 参与者缩略图已移至底部参会人员栏
            ],
          ),
        ),
      );
}
