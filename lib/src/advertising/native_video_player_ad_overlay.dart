import 'package:flutter/material.dart';

import '../controllers/native_video_player_controller.dart';
import 'native_video_player_ad_event.dart';

/// Ad status layer rendered inside the existing player stack.
class NativeVideoPlayerAdOverlay extends StatelessWidget {
  const NativeVideoPlayerAdOverlay({required this.controller, super.key});

  final NativeVideoPlayerController controller;

  bool _isAdSession(NativeVideoPlayerAdSessionState state) => switch (state) {
    NativeVideoPlayerAdSessionState.adLoading ||
    NativeVideoPlayerAdSessionState.adPlaying ||
    NativeVideoPlayerAdSessionState.adPaused ||
    NativeVideoPlayerAdSessionState.adCompleted ||
    NativeVideoPlayerAdSessionState.adSkipped ||
    NativeVideoPlayerAdSessionState.adFailed => true,
    _ => false,
  };

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<NativeVideoPlayerAdSessionState>(
      stream: controller.advertisementController.sessionStateStream,
      initialData: controller.advertisementController.sessionState,
      builder: (context, sessionSnapshot) {
        final session =
            sessionSnapshot.data ?? NativeVideoPlayerAdSessionState.contentIdle;
        if (!_isAdSession(session)) return const SizedBox.shrink();

        return StreamBuilder<NativeVideoPlayerAdEvent>(
          stream: controller.advertisementController.events,
          initialData: controller.advertisementController.lastEvent,
          builder: (context, eventSnapshot) {
            final event = eventSnapshot.data;
            final metadata = event?.metadata;
            final duration = event?.duration ?? metadata?.duration;
            final position = event?.position;
            final remaining = duration != null && position != null
                ? duration - position
                : null;
            final hasError =
                session == NativeVideoPlayerAdSessionState.adFailed;
            final isPlaying =
                session == NativeVideoPlayerAdSessionState.adPlaying;
            final skipOffset = metadata?.skipTimeOffset;
            final skipAvailable =
                metadata?.isSkippable == true &&
                isPlaying &&
                (skipOffset == null ||
                    position == null ||
                    position >= skipOffset);
            final skipRemaining = skipOffset != null && position != null
                ? skipOffset - position
                : null;

            return SizedBox.expand(
              child: IgnorePointer(
                ignoring:
                    session == NativeVideoPlayerAdSessionState.adCompleted,
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[Colors.black54, Colors.transparent],
                    ),
                  ),
                  child: SafeArea(
                    child: Stack(
                      children: <Widget>[
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Text(
                                hasError
                                    ? 'Advertisement unavailable'
                                    : 'Sponsored',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (remaining != null && !remaining.isNegative)
                                Text(
                                  '${remaining.inSeconds}s remaining',
                                  style: const TextStyle(color: Colors.white70),
                                ),
                              if (duration != null && position != null)
                                SizedBox(
                                  width: 180,
                                  child: LinearProgressIndicator(
                                    value: duration.inMilliseconds == 0
                                        ? null
                                        : (position.inMilliseconds /
                                                  duration.inMilliseconds)
                                              .clamp(0.0, 1.0),
                                    backgroundColor: Colors.white30,
                                    color: Colors.white,
                                  ),
                                ),
                              if (session ==
                                  NativeVideoPlayerAdSessionState.adLoading)
                                const Padding(
                                  padding: EdgeInsets.only(top: 6),
                                  child: SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (metadata?.isSkippable == true && isPlaying)
                          Positioned(
                            top: 12,
                            right: 12,
                            child: OutlinedButton(
                              onPressed: skipAvailable
                                  ? controller
                                        .advertisementController
                                        .skipAdvertisement
                                  : null,
                              child: Text(
                                skipAvailable
                                    ? 'Skip Ad'
                                    : 'Skip in ${((skipRemaining?.inMilliseconds ?? 0) + 999) ~/ 1000}',
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
