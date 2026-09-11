import 'package:flutter/foundation.dart';

/// The format served by an advertising tag URL.
///
/// [auto] leaves format detection to the eventual platform advertising
/// implementation. A VAST response can describe one break; a VMAP response
/// can describe a schedule of breaks.
enum NativeVideoPlayerAdTagType {
  /// Let the native adapter determine the tag format.
  auto,

  /// A VAST ad tag.
  vast,

  /// A VMAP ad tag whose schedule is owned by Google IMA.
  vmap,
}

/// Where a scheduled in-stream ad break belongs relative to content.
enum NativeVideoPlayerAdBreakType {
  /// Plays before content.
  preRoll,

  /// Plays at a configured content position.
  midRoll,

  /// Plays after content reaches completion.
  postRoll,
}

/// Optional skip policy for an ad break.
///
/// A platform adapter must still respect whether the served ad is
/// actually skippable. [allowUserSkip] is an application-level gate; setting
/// it to `false` must never make a non-skippable served ad skippable. When
/// [skipAfter] is null, the ad response/provider determines the skip offset.
@immutable
class NativeVideoPlayerAdSkipConfiguration {
  /// Creates an optional application-level skip policy.
  const NativeVideoPlayerAdSkipConfiguration({
    this.allowUserSkip = true,
    this.skipAfter,
  });

  /// Whether the player may present a skip action for a skippable ad.
  final bool allowUserSkip;

  /// Optional client policy for when a skip action becomes available.
  final Duration? skipAfter;

  Map<String, Object> toMap() => <String, Object>{
    'allowUserSkip': allowUserSkip,
    if (skipAfter != null) 'skipAfterMs': skipAfter!.inMilliseconds,
  };

  factory NativeVideoPlayerAdSkipConfiguration.fromMap(
    Map<dynamic, dynamic> map,
  ) {
    final int? skipAfterMs = (map['skipAfterMs'] as num?)?.toInt();
    return NativeVideoPlayerAdSkipConfiguration(
      allowUserSkip: map['allowUserSkip'] as bool? ?? true,
      skipAfter: skipAfterMs == null
          ? null
          : Duration(milliseconds: skipAfterMs),
    );
  }
}

/// Optional app-provided context accompanying an advertising request.
///
/// This is content/request metadata, not metadata parsed from a served ad.
/// [customParameters] is intentionally restricted to string pairs so it is
/// safe to transport unchanged across the existing standard method channel.
@immutable
class NativeVideoPlayerAdRequestMetadata {
  /// Creates content metadata passed with the ad request.
  const NativeVideoPlayerAdRequestMetadata({
    this.contentId,
    this.contentTitle,
    this.contentUrl,
    this.customParameters = const <String, String>{},
  });

  /// Application-defined content identifier.
  final String? contentId;

  /// Content title sent with the request.
  final String? contentTitle;

  /// Content URL sent with the request.
  final Uri? contentUrl;

  /// Additional string request parameters.
  final Map<String, String> customParameters;

  Map<String, Object> toMap() => <String, Object>{
    'contentId': ?contentId,
    'contentTitle': ?contentTitle,
    'contentUrl': ?contentUrl?.toString(),
    if (customParameters.isNotEmpty) 'customParameters': customParameters,
  };
}

/// A planned ad break for a content load.
///
/// A VAST tag can be supplied per break through [adTagUrl], or inherited from
/// [NativeVideoPlayerAdConfiguration.adTagUrl]. VMAP configurations normally
/// omit [adBreaks], because the VMAP response supplies the schedule.
@immutable
class NativeVideoPlayerAdBreak {
  /// Creates a typed advertisement break.
  const NativeVideoPlayerAdBreak({
    required this.id,
    required this.type,
    this.position,
    this.adTagUrl,
    this.skipConfiguration,
  }) : assert(
         type != NativeVideoPlayerAdBreakType.midRoll || position != null,
         'A mid-roll break requires a content position.',
       ),
       assert(
         type == NativeVideoPlayerAdBreakType.midRoll || position == null,
         'Only a mid-roll break can have a content position.',
       ),
       assert(id != '');

  /// A break scheduled before content begins.
  const NativeVideoPlayerAdBreak.preRoll({
    required String id,
    Uri? adTagUrl,
    NativeVideoPlayerAdSkipConfiguration? skipConfiguration,
  }) : this(
         id: id,
         type: NativeVideoPlayerAdBreakType.preRoll,
         adTagUrl: adTagUrl,
         skipConfiguration: skipConfiguration,
       );

  /// A break scheduled at [position] in content time.
  const NativeVideoPlayerAdBreak.midRoll({
    required String id,
    required Duration position,
    Uri? adTagUrl,
    NativeVideoPlayerAdSkipConfiguration? skipConfiguration,
  }) : this(
         id: id,
         type: NativeVideoPlayerAdBreakType.midRoll,
         position: position,
         adTagUrl: adTagUrl,
         skipConfiguration: skipConfiguration,
       );

  /// A break scheduled after content completes.
  const NativeVideoPlayerAdBreak.postRoll({
    required String id,
    Uri? adTagUrl,
    NativeVideoPlayerAdSkipConfiguration? skipConfiguration,
  }) : this(
         id: id,
         type: NativeVideoPlayerAdBreakType.postRoll,
         adTagUrl: adTagUrl,
         skipConfiguration: skipConfiguration,
       );

  /// Stable app-defined identifier for this planned break.
  /// Stable application-defined break identifier.
  final String id;

  /// Whether this break is before, during, or after content.
  /// Position category of this break.
  final NativeVideoPlayerAdBreakType type;

  /// Content position for a [NativeVideoPlayerAdBreakType.midRoll].
  /// Content position for a mid-roll break.
  final Duration? position;

  /// Optional VAST/VMAP tag URL overriding the configuration-level tag.
  /// Optional tag override for this break.
  final Uri? adTagUrl;

  /// Optional break-level override for the configuration-wide skip policy.
  /// Optional break-specific skip policy.
  final NativeVideoPlayerAdSkipConfiguration? skipConfiguration;

  Map<String, Object> toMap() => <String, Object>{
    'id': id,
    'type': type.name,
    if (position != null) 'positionMs': position!.inMilliseconds,
    if (adTagUrl != null) 'adTagUrl': adTagUrl.toString(),
    if (skipConfiguration != null)
      'skipConfiguration': skipConfiguration!.toMap(),
  };

  factory NativeVideoPlayerAdBreak.fromMap(Map<dynamic, dynamic> map) {
    final String typeName = map['type'] as String? ?? 'preRoll';
    return NativeVideoPlayerAdBreak(
      id: map['id'] as String? ?? 'unknown',
      type: switch (typeName) {
        'midRoll' => NativeVideoPlayerAdBreakType.midRoll,
        'postRoll' => NativeVideoPlayerAdBreakType.postRoll,
        _ => NativeVideoPlayerAdBreakType.preRoll,
      },
      position: (map['positionMs'] as num?) == null
          ? null
          : Duration(milliseconds: (map['positionMs'] as num).toInt()),
      adTagUrl: (map['adTagUrl'] as String?) == null
          ? null
          : Uri.tryParse(map['adTagUrl'] as String),
      skipConfiguration: map['skipConfiguration'] is Map
          ? NativeVideoPlayerAdSkipConfiguration.fromMap(
              map['skipConfiguration'] as Map<dynamic, dynamic>,
            )
          : null,
    );
  }
}

/// Optional advertising setup for one content [NativeVideoPlayerController.load]
/// operation.
///
/// This is deliberately provider-neutral. It carries a VAST or VMAP tag and
/// an optional client-side schedule. Native Google IMA adapters request and
/// play the configured tag without changing the content-playback API.
@immutable
class NativeVideoPlayerAdConfiguration {
  /// Creates optional advertising configuration for one content load.
  const NativeVideoPlayerAdConfiguration({
    required this.adTagUrl,
    this.tagType = NativeVideoPlayerAdTagType.auto,
    this.enabled = true,
    this.adBreaks = const <NativeVideoPlayerAdBreak>[],
    this.timeout,
    this.skipConfiguration,
    this.requestMetadata,
    this.resumeContentOnError = true,
  });

  /// Configuration for a VAST tag and an optional client-side break schedule.
  const NativeVideoPlayerAdConfiguration.vast({
    required Uri adTagUrl,
    bool enabled = true,
    List<NativeVideoPlayerAdBreak> adBreaks =
        const <NativeVideoPlayerAdBreak>[],
    Duration? timeout,
    NativeVideoPlayerAdSkipConfiguration? skipConfiguration,
    NativeVideoPlayerAdRequestMetadata? requestMetadata,
    bool resumeContentOnError = true,
  }) : this(
         adTagUrl: adTagUrl,
         tagType: NativeVideoPlayerAdTagType.vast,
         enabled: enabled,
         adBreaks: adBreaks,
         timeout: timeout,
         skipConfiguration: skipConfiguration,
         requestMetadata: requestMetadata,
         resumeContentOnError: resumeContentOnError,
       );

  /// Configuration for a VMAP tag. VMAP commonly supplies its own schedule,
  /// but [adBreaks] remains available for provider-specific future adapters.
  const NativeVideoPlayerAdConfiguration.vmap({
    required Uri adTagUrl,
    bool enabled = true,
    List<NativeVideoPlayerAdBreak> adBreaks =
        const <NativeVideoPlayerAdBreak>[],
    Duration? timeout,
    NativeVideoPlayerAdSkipConfiguration? skipConfiguration,
    NativeVideoPlayerAdRequestMetadata? requestMetadata,
    bool resumeContentOnError = true,
  }) : this(
         adTagUrl: adTagUrl,
         tagType: NativeVideoPlayerAdTagType.vmap,
         enabled: enabled,
         adBreaks: adBreaks,
         timeout: timeout,
         skipConfiguration: skipConfiguration,
         requestMetadata: requestMetadata,
         resumeContentOnError: resumeContentOnError,
       );

  /// VAST or VMAP ad-tag URL.
  /// VAST or VMAP tag URL.
  final Uri adTagUrl;

  /// Declared tag format, or [NativeVideoPlayerAdTagType.auto] to detect it
  /// in the eventual native adapter.
  /// Tag format supplied to the native adapter.
  final NativeVideoPlayerAdTagType tagType;

  /// Whether this configuration should participate in the current content
  /// load. The default remains enabled for backward compatibility.
  /// Whether advertising participates in this load.
  final bool enabled;

  /// Optional app-provided pre/mid/post-roll schedule.
  /// Manual pre-roll, mid-roll, and post-roll definitions.
  final List<NativeVideoPlayerAdBreak> adBreaks;

  /// Optional deadline for the future ad request/load lifecycle.
  /// Optional native ad request timeout.
  final Duration? timeout;

  /// Default skip policy for breaks that do not provide an override.
  /// Default skip policy for configured breaks.
  final NativeVideoPlayerAdSkipConfiguration? skipConfiguration;

  /// Optional typed content context for the future ad request.
  /// Content metadata accompanying the request.
  final NativeVideoPlayerAdRequestMetadata? requestMetadata;

  /// Whether a failed ad request or break returns orchestration to the
  /// current content state. Defaults to true so an advertising failure does
  /// not block content playback. Set false only when the application needs a
  /// failed ad break to remain visible to its own recovery flow.
  /// Whether content resumes automatically after an ad failure.
  final bool resumeContentOnError;

  /// All configured pre-roll breaks. A configuration usually has zero or one.
  List<NativeVideoPlayerAdBreak> get preRollBreaks =>
      _breaksOfType(NativeVideoPlayerAdBreakType.preRoll);

  /// All configured mid-roll breaks, in caller-supplied order.
  List<NativeVideoPlayerAdBreak> get midRollBreaks =>
      _breaksOfType(NativeVideoPlayerAdBreakType.midRoll);

  /// All configured post-roll breaks. A configuration usually has zero or one.
  List<NativeVideoPlayerAdBreak> get postRollBreaks =>
      _breaksOfType(NativeVideoPlayerAdBreakType.postRoll);

  Map<String, Object> toMap() => <String, Object>{
    'adTagUrl': adTagUrl.toString(),
    'tagType': tagType.name,
    if (!enabled) 'enabled': false,
    if (adBreaks.isNotEmpty)
      'adBreaks': adBreaks.map((breakInfo) => breakInfo.toMap()).toList(),
    if (timeout != null) 'timeoutMs': timeout!.inMilliseconds,
    if (skipConfiguration != null)
      'skipConfiguration': skipConfiguration!.toMap(),
    if (requestMetadata != null) 'requestMetadata': requestMetadata!.toMap(),
    if (!resumeContentOnError) 'resumeContentOnError': false,
  };

  List<NativeVideoPlayerAdBreak> _breaksOfType(
    NativeVideoPlayerAdBreakType type,
  ) => List<NativeVideoPlayerAdBreak>.unmodifiable(
    adBreaks.where((breakInfo) => breakInfo.type == type),
  );
}
