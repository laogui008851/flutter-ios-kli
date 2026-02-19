import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:livekit_example/theme.dart';

import 'dart:async';
import 'no_video.dart';
import 'participant_info.dart';
import 'participant_stats.dart';

abstract class ParticipantWidget extends StatefulWidget {
  // Convenience method to return relevant widget for participant
  static ParticipantWidget widgetFor(ParticipantTrack participantTrack, {bool showStatsLayer = false}) {
    if (participantTrack.participant is LocalParticipant) {
      return LocalParticipantWidget(
          participantTrack.participant as LocalParticipant, participantTrack.type, showStatsLayer);
    } else if (participantTrack.participant is RemoteParticipant) {
      return RemoteParticipantWidget(
          participantTrack.participant as RemoteParticipant, participantTrack.type, showStatsLayer);
    }
    throw UnimplementedError('Unknown participant type');
  }

  // Must be implemented by child class
  abstract final Participant participant;
  abstract final ParticipantTrackType type;
  abstract final bool showStatsLayer;
  final VideoQuality quality;

  const ParticipantWidget({
    this.quality = VideoQuality.MEDIUM,
    super.key,
  });
}

class LocalParticipantWidget extends ParticipantWidget {
  @override
  final LocalParticipant participant;
  @override
  final ParticipantTrackType type;
  @override
  final bool showStatsLayer;

  const LocalParticipantWidget(
    this.participant,
    this.type,
    this.showStatsLayer, {
    super.key,
  });

  @override
  State<StatefulWidget> createState() => _LocalParticipantWidgetState();
}

class RemoteParticipantWidget extends ParticipantWidget {
  @override
  final RemoteParticipant participant;
  @override
  final ParticipantTrackType type;
  @override
  final bool showStatsLayer;

  const RemoteParticipantWidget(
    this.participant,
    this.type,
    this.showStatsLayer, {
    super.key,
  });

  @override
  State<StatefulWidget> createState() => _RemoteParticipantWidgetState();
}

abstract class _ParticipantWidgetState<T extends ParticipantWidget> extends State<T> {
  bool _visible = true;
  bool _showTrackControls = false;
  VideoTrack? get activeVideoTrack;
  AudioTrack? get activeAudioTrack;
  TrackPublication? get videoPublication;
  TrackPublication? get audioPublication;
  bool get isScreenShare => widget.type == ParticipantTrackType.kScreenShare;
  bool get isLocal => widget.participant is LocalParticipant;
  EventsListener<ParticipantEvent>? _listener;

  @override
  void initState() {
    super.initState();
    _listener = widget.participant.createListener();
    _listener?.on<TranscriptionEvent>((e) {
      for (var seg in e.segments) {
        print('Transcription: ${seg.text} ${seg.isFinal}');
      }
    });

    widget.participant.addListener(_onParticipantChanged);
    _onParticipantChanged();
  }

  @override
  void dispose() {
    widget.participant.removeListener(_onParticipantChanged);
    unawaited(_listener?.dispose());
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant T oldWidget) {
    oldWidget.participant.removeListener(_onParticipantChanged);
    widget.participant.addListener(_onParticipantChanged);
    _onParticipantChanged();
    super.didUpdateWidget(oldWidget);
  }

  // Notify Flutter that UI re-build is required, but we don't set anything here
  // since the updated values are computed properties.
  void _onParticipantChanged() => setState(() {});

  // Widgets to show above the info bar
  List<Widget> extraWidgets(bool isScreenShare) => [];

  void _toggleTrackControls() {
    setState(() {
      _showTrackControls = !_showTrackControls;
    });
  }

  @override
  Widget build(BuildContext ctx) => Container(
        foregroundDecoration: BoxDecoration(
          border: widget.participant.isSpeaking && !isScreenShare
              ? Border.all(
                  width: 5,
                  color: LKColors.lkBlue,
                )
              : null,
        ),
        decoration: BoxDecoration(
          color: Theme.of(ctx).cardColor,
        ),
        child: Stack(
          children: [
            // Video
            InkWell(
              onTap: () => setState(() => _visible = !_visible),
              child: _buildVideoContent(),
            ),
            // 参与者信息栏和控制菜单已移至底部参会人员栏
            if (widget.showStatsLayer)
              Positioned(
                  top: 130,
                  right: 30,
                  child: ParticipantStatsWidget(
                    participant: widget.participant,
                  )),
            // 音频波形可视化已禁用
            // if (activeAudioTrack != null && !activeAudioTrack!.muted)
            //   Positioned(
            //     top: 10,
            //     right: 10,
            //     left: 10,
            //     bottom: 10,
            //     child: SoundWaveformWidget(
            //       key: ValueKey(activeAudioTrack!.hashCode),
            //       audioTrack: activeAudioTrack!,
            //       width: 8,
            //     ),
            //   ),
          ],
        ),
      );

  Widget _buildVideoContent() {
    final isLocalScreenShare = isLocal && isScreenShare;
    if (!isLocalScreenShare && activeVideoTrack != null && !activeVideoTrack!.muted) {
      return VideoTrackRenderer(
        renderMode: VideoRenderMode.auto,
        activeVideoTrack!,
      );
    }
    if (isLocalScreenShare) {
      return const _LocalScreenSharePlaceholder();
    }
    return const NoVideoWidget();
  }
}

class _LocalScreenSharePlaceholder extends StatelessWidget {
  const _LocalScreenSharePlaceholder();

  @override
  Widget build(BuildContext context) => Container(
        alignment: Alignment.center,
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.screen_share_outlined,
              size: 48,
              color: Colors.white70,
            ),
            SizedBox(height: 8),
            Text(
              'Local screen share preview hidden',
              style: TextStyle(color: Colors.white70),
            ),
          ],
        ),
      );
}

class _LocalParticipantWidgetState extends _ParticipantWidgetState<LocalParticipantWidget> {
  @override
  LocalTrackPublication<LocalVideoTrack>? get videoPublication => widget.participant.videoTrackPublications
      .where((element) => element.source == widget.type.lkVideoSourceType)
      .firstOrNull;

  @override
  LocalTrackPublication<LocalAudioTrack>? get audioPublication => widget.participant.audioTrackPublications
      .where((element) => element.source == widget.type.lkAudioSourceType)
      .firstOrNull;

  @override
  VideoTrack? get activeVideoTrack => videoPublication?.track;

  @override
  AudioTrack? get activeAudioTrack => audioPublication?.track;
}

class _RemoteParticipantWidgetState extends _ParticipantWidgetState<RemoteParticipantWidget> {
  @override
  RemoteTrackPublication<RemoteVideoTrack>? get videoPublication => widget.participant.videoTrackPublications
      .where((element) => element.source == widget.type.lkVideoSourceType)
      .firstOrNull;

  @override
  RemoteTrackPublication<RemoteAudioTrack>? get audioPublication => widget.participant.audioTrackPublications
      .where((element) => element.source == widget.type.lkAudioSourceType)
      .firstOrNull;

  @override
  VideoTrack? get activeVideoTrack => videoPublication?.track;

  @override
  AudioTrack? get activeAudioTrack => audioPublication?.track;

  // 远程参与者控制菜单已移除（简化界面）
}

class RemoteTrackPublicationMenuWidget extends StatelessWidget {
  final IconData icon;
  final RemoteTrackPublication pub;
  const RemoteTrackPublicationMenuWidget({
    required this.pub,
    required this.icon,
    super.key,
  });

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.black.withValues(alpha: 0.3),
        child: PopupMenuButton<Function>(
          tooltip: 'Subscribe menu',
          icon: Icon(icon,
              color: {
                TrackSubscriptionState.notAllowed: Colors.red,
                TrackSubscriptionState.unsubscribed: Colors.grey,
                TrackSubscriptionState.subscribed: Colors.green,
              }[pub.subscriptionState]),
          onSelected: (value) => value(),
          itemBuilder: (BuildContext context) => <PopupMenuEntry<Function>>[
            // Subscribe/Unsubscribe
            if (pub.subscribed == false)
              PopupMenuItem(
                child: const Text('Subscribe'),
                value: () => pub.subscribe(),
              )
            else if (pub.subscribed == true)
              PopupMenuItem(
                child: const Text('Un-subscribe'),
                value: () => pub.unsubscribe(),
              ),
          ],
        ),
      );
}

class RemoteTrackFPSMenuWidget extends StatelessWidget {
  final IconData icon;
  final RemoteTrackPublication pub;
  const RemoteTrackFPSMenuWidget({
    required this.pub,
    required this.icon,
    super.key,
  });

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.black.withValues(alpha: 0.3),
        child: PopupMenuButton<Function>(
          tooltip: 'Preferred FPS',
          icon: Icon(icon, color: Colors.white),
          onSelected: (value) => value(),
          itemBuilder: (BuildContext context) => <PopupMenuEntry<Function>>[
            PopupMenuItem(
              child: const Text('30'),
              value: () => pub.setVideoFPS(30),
            ),
            PopupMenuItem(
              child: const Text('15'),
              value: () => pub.setVideoFPS(15),
            ),
            PopupMenuItem(
              child: const Text('8'),
              value: () => pub.setVideoFPS(8),
            ),
          ],
        ),
      );
}

class RemoteTrackQualityMenuWidget extends StatelessWidget {
  final IconData icon;
  final RemoteTrackPublication pub;
  const RemoteTrackQualityMenuWidget({
    required this.pub,
    required this.icon,
    super.key,
  });

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.black.withValues(alpha: 0.3),
        child: PopupMenuButton<Function>(
          tooltip: 'Preferred Quality',
          icon: Icon(icon, color: Colors.white),
          onSelected: (value) => value(),
          itemBuilder: (BuildContext context) => <PopupMenuEntry<Function>>[
            PopupMenuItem(
              child: const Text('HIGH'),
              value: () => pub.setVideoQuality(VideoQuality.HIGH),
            ),
            PopupMenuItem(
              child: const Text('MEDIUM'),
              value: () => pub.setVideoQuality(VideoQuality.MEDIUM),
            ),
            PopupMenuItem(
              child: const Text('LOW'),
              value: () => pub.setVideoQuality(VideoQuality.LOW),
            ),
          ],
        ),
      );
}
