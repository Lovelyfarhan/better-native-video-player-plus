import 'package:flutter/foundation.dart';

import 'native_video_player_ad_configuration.dart';

/// Lifecycle state of the optional advertising subsystem.
enum NativeVideoPlayerAdPlaybackState {
  /// Advertising is not configured.
  disabled,

  /// No ad is currently active.
  idle,

  /// An ad request is in progress.
  requesting,

  /// A break/ad is ready to start.
  ready,

  /// An advertisement is playing.
  playing,

  /// An advertisement is paused.
  paused,

  /// An advertisement completed.
  completed,

  /// An advertisement was skipped.
  skipped,

  /// An advertisement failed.
  error,

  /// The advertising controller was disposed.
  disposed,
}

/// The current orchestration phase between the authoritative content player
/// and the optional advertising subsystem.
///
/// Content variants mirror the existing [PlayerActivityState] without
/// replacing it: the content controller remains the source of truth for
/// loading, buffering, playback, and errors. Ad variants are entered only by
/// valid events accepted by [NativeVideoPlayerAdvertisementController].
enum NativeVideoPlayerAdSessionState {
  contentIdle,
  contentInitializing,
  contentInitialized,
  contentLoading,
  contentLoaded,
  contentPlaying,
  contentPaused,
  contentBuffering,
  contentCompleted,
  contentStopped,
  contentError,
  adLoading,
  adPlaying,
  adPaused,
  adCompleted,
  adSkipped,
  adFailed,
  disposed,
}

/// Provider-neutral events emitted for an ad request, break, or individual ad.
enum NativeVideoPlayerAdEventType {
  /// The native adapter began requesting ads.
  requestStarted,

  /// An ad/break was loaded and is ready.
  breakReady,

  /// A break started.
  breakStarted,

  /// An individual ad started.
  adStarted,
  adProgress,
  firstQuartile,
  midpoint,
  thirdQuartile,
  adPaused,
  adResumed,
  adSkipped,
  adCompleted,
  breakCompleted,
  allAdsCompleted,
  clicked,
  error,
  unknown,
}

/// Structured failure information for an advertising request or playback.
@immutable
class NativeVideoPlayerAdError {
  /// Creates structured ad failure information.
  const NativeVideoPlayerAdError({
    required this.code,
    required this.message,
    this.details,
  });

  /// Provider/platform error code.
  final String code;

  /// Human-readable failure message.
  final String message;

  /// Optional provider-specific details.
  final Object? details;

  factory NativeVideoPlayerAdError.fromMap(Map<dynamic, dynamic> map) {
    return NativeVideoPlayerAdError(
      code: map['code'] as String? ?? 'unknown',
      message: map['message'] as String? ?? 'Unknown advertising error.',
      details: map['details'],
    );
  }
}

/// Metadata supplied by the eventual advertising platform for one served ad.
///
/// Every field is optional because VAST/VMAP responses and future providers do
/// not guarantee the same metadata. This model does not parse ad documents;
/// it only gives the native adapter a typed event payload to report.
@immutable
class NativeVideoPlayerAdMetadata {
  /// Creates metadata for one served advertisement.
  const NativeVideoPlayerAdMetadata({
    this.adId,
    this.creativeId,
    this.adSystem,
    this.title,
    this.advertiserName,
    this.clickThroughUrl,
    this.duration,
    this.isSkippable,
    this.skipTimeOffset,
  });

  /// VAST/IMA ad identifier.
  final String? adId;

  /// Selected creative identifier.
  final String? creativeId;

  /// Ad system name.
  final String? adSystem;

  /// Served ad title.
  final String? title;

  /// Advertiser name.
  final String? advertiserName;

  /// Served ad click-through URL, when supplied.
  final Uri? clickThroughUrl;

  /// Served ad duration.
  final Duration? duration;

  /// Whether IMA reports the served ad as skippable.
  final bool? isSkippable;

  /// IMA/VAST skip offset for the served ad.
  final Duration? skipTimeOffset;

  factory NativeVideoPlayerAdMetadata.fromMap(Map<dynamic, dynamic> map) {
    final int? durationMs = (map['durationMs'] as num?)?.toInt();
    final int? skipTimeOffsetMs = (map['skipTimeOffsetMs'] as num?)?.toInt();
    return NativeVideoPlayerAdMetadata(
      adId: map['adId'] as String?,
      creativeId: map['creativeId'] as String?,
      adSystem: map['adSystem'] as String?,
      title: map['title'] as String?,
      advertiserName: map['advertiserName'] as String?,
      clickThroughUrl: (map['clickThroughUrl'] as String?) == null
          ? null
          : Uri.tryParse(map['clickThroughUrl'] as String),
      duration: durationMs == null ? null : Duration(milliseconds: durationMs),
      isSkippable: map['isSkippable'] as bool?,
      skipTimeOffset: skipTimeOffsetMs == null
          ? null
          : Duration(milliseconds: skipTimeOffsetMs),
    );
  }
}

/// A provider-neutral advertising event.
///
/// Pod metadata is populated for ad responses that contain multiple ads in a
/// break. Indices are one-based when provided by the platform adapter.
@immutable
class NativeVideoPlayerAdEvent {
  /// Creates a normalized provider-neutral advertisement event.
  const NativeVideoPlayerAdEvent({
    required this.type,
    required this.rawType,
    this.adBreak,
    this.adBreakId,
    this.metadata,
    this.position,
    this.duration,
    this.adPositionInPod,
    this.totalAdsInPod,
    this.error,
    this.timestamp,
    this.contentId,
    this.contentTitle,
    this.contentUrl,
  });

  /// Normalized event type.
  final NativeVideoPlayerAdEventType type;

  /// Original provider event name.
  final String rawType;

  /// Full configured or reported ad-break identity.
  final NativeVideoPlayerAdBreak? adBreak;

  /// Stable identity of the affected break, even when the native event does
  /// not need to repeat the complete configured break payload.
  final String? adBreakId;

  /// Metadata for the individual served ad, when supplied by the platform.
  /// Metadata for the served ad.
  final NativeVideoPlayerAdMetadata? metadata;

  /// Current ad position for progress events.
  final Duration? position;

  /// Current ad duration.
  final Duration? duration;

  /// One-based position in an ad pod.
  final int? adPositionInPod;

  /// Number of ads in the current pod.
  final int? totalAdsInPod;

  /// Structured error for error events.
  final NativeVideoPlayerAdError? error;

  /// UTC event timestamp when supplied or normalized by Dart.
  final DateTime? timestamp;

  /// Application content identifier.
  final String? contentId;

  /// Application content title.
  final String? contentTitle;

  /// Application content URL.
  final Uri? contentUrl;

  NativeVideoPlayerAdEvent copyWithContext({
    DateTime? timestamp,
    String? contentId,
    String? contentTitle,
    Uri? contentUrl,
  }) => NativeVideoPlayerAdEvent(
    type: type,
    rawType: rawType,
    adBreak: adBreak,
    adBreakId: adBreakId,
    metadata: metadata,
    position: position,
    duration: duration,
    adPositionInPod: adPositionInPod,
    totalAdsInPod: totalAdsInPod,
    error: error,
    timestamp: timestamp ?? this.timestamp,
    contentId: contentId ?? this.contentId,
    contentTitle: contentTitle ?? this.contentTitle,
    contentUrl: contentUrl ?? this.contentUrl,
  );

  factory NativeVideoPlayerAdEvent.fromMap(Map<dynamic, dynamic> map) {
    final rawType =
        map['adEventType'] as String? ?? map['type'] as String? ?? 'unknown';
    final breakMap = map['adBreak'];
    final errorMap = map['error'];
    final adBreak = breakMap is Map
        ? NativeVideoPlayerAdBreak.fromMap(breakMap)
        : null;
    final metadataMap = map['metadata'];
    return NativeVideoPlayerAdEvent(
      type: _eventTypeFromWire(rawType),
      rawType: rawType,
      adBreak: adBreak,
      adBreakId: map['adBreakId'] as String? ?? adBreak?.id,
      metadata: metadataMap is Map
          ? NativeVideoPlayerAdMetadata.fromMap(metadataMap)
          : null,
      position: _durationFromMilliseconds(map['positionMs']),
      duration: _durationFromMilliseconds(map['durationMs']),
      adPositionInPod: (map['adPositionInPod'] as num?)?.toInt(),
      totalAdsInPod: (map['totalAdsInPod'] as num?)?.toInt(),
      error: errorMap is Map
          ? NativeVideoPlayerAdError.fromMap(errorMap)
          : null,
      timestamp: _timestampFromMilliseconds(map['timestampMs']),
      contentId: map['contentId'] as String?,
      contentTitle: map['contentTitle'] as String?,
      contentUrl: (map['contentUrl'] as String?) == null
          ? null
          : Uri.tryParse(map['contentUrl'] as String),
    );
  }

  static Duration? _durationFromMilliseconds(Object? value) {
    final milliseconds = (value as num?)?.toInt();
    return milliseconds == null ? null : Duration(milliseconds: milliseconds);
  }

  static DateTime? _timestampFromMilliseconds(Object? value) {
    final milliseconds = (value as num?)?.toInt();
    return milliseconds == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
  }

  static NativeVideoPlayerAdEventType _eventTypeFromWire(String value) {
    return switch (value) {
      'requestStarted' => NativeVideoPlayerAdEventType.requestStarted,
      'breakReady' => NativeVideoPlayerAdEventType.breakReady,
      'breakStarted' => NativeVideoPlayerAdEventType.breakStarted,
      'adStarted' => NativeVideoPlayerAdEventType.adStarted,
      'adProgress' => NativeVideoPlayerAdEventType.adProgress,
      'firstQuartile' => NativeVideoPlayerAdEventType.firstQuartile,
      'midpoint' => NativeVideoPlayerAdEventType.midpoint,
      'thirdQuartile' => NativeVideoPlayerAdEventType.thirdQuartile,
      'adPaused' => NativeVideoPlayerAdEventType.adPaused,
      'adResumed' => NativeVideoPlayerAdEventType.adResumed,
      'adSkipped' => NativeVideoPlayerAdEventType.adSkipped,
      'adCompleted' => NativeVideoPlayerAdEventType.adCompleted,
      'breakCompleted' => NativeVideoPlayerAdEventType.breakCompleted,
      'allAdsCompleted' => NativeVideoPlayerAdEventType.allAdsCompleted,
      'clicked' => NativeVideoPlayerAdEventType.clicked,
      'error' => NativeVideoPlayerAdEventType.error,
      _ => NativeVideoPlayerAdEventType.unknown,
    };
  }
}
