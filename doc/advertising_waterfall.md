# VAST Tag Waterfall — Complete Guide

This document is the full reference for the **VAST tag waterfall / fallback**
feature of `better_native_video_player_plus`. It expands on the
[Advertisement Support](../README.md#advertisement-support) section of the README
with the complete API surface, the exact ordering and error rules, and runnable
examples.

For the whole advertising system (placements, VMAP, skip handling, the state
machine), read the README first. This file assumes you already know how to play
a single VAST pre-roll.

---

## 1. Why a waterfall

A VAST tag is a request to an ad server. A perfectly healthy server can still
answer with **nothing**:

- the campaign has no remaining impressions today (classic “no fill”),
- the VAST document is valid but contains no `<Ad>`,
- a wrapper chain resolves to an empty document,
- the server or the CDN is slow and never responds.

With one tag, every one of those cases means _no ad_ — even though other ad
networks would have filled the break. A waterfall fixes that by giving the
player an **ordered list of tags** and letting it try the next one whenever the
current one produces nothing.

```text
request tag 1 → ad plays?         → done
             → no fill / timeout  → request tag 2
request tag 2 → ad plays?         → done
             → no fill / timeout  → request tag 3
request tag 3 → ...               → until all tags fail
```

The waterfall is implemented entirely in Dart
(`lib/src/advertising/native_video_player_ad_waterfall.dart`) on top of the
existing Google IMA bridge, so it works on Android and iOS without native
changes, and it reuses the single `AdsLoader` per content load.

---

## 2. Quick start

```dart
import 'package:better_native_video_player_plus/better_native_video_player_plus.dart';

final controller = NativeVideoPlayerController(id: 1, autoPlay: true);
await controller.initialize();

// Subscribe BEFORE load(): the first tagRequested fires during load().
controller.advertisementController.events.listen((event) {
  switch (event.type) {
    case NativeVideoPlayerAdEventType.tagRequested:
      print('trying tag ${event.tagIndex! + 1}/${event.totalTags}: ${event.adTagUrl}');
    case NativeVideoPlayerAdEventType.tagFailed:
      print('tag ${event.tagIndex} failed: ${event.error?.code} → falling back');
    case NativeVideoPlayerAdEventType.waterfallExhausted:
      print('every ad tag failed — content continues');
    case NativeVideoPlayerAdEventType.adStarted:
      print('ad playing from tag ${event.tagIndex}');
    default:
      break;
  }
});

await controller.loadUrl(
  url: 'https://example.com/video.mp4',
  adConfiguration: NativeVideoPlayerAdConfiguration.vastWaterfall(
    vastTags: <Uri>[
      Uri.parse('https://ads.example.com/primary.xml'),
      Uri.parse('https://backup.example.com/secondary.xml'),
      Uri.parse('https://fallback.example.com/tertiary.xml'),
    ],
    perTagTimeout: const Duration(seconds: 6), // default is 8s
    adBreaks: const <NativeVideoPlayerAdBreak>[
      NativeVideoPlayerAdBreak.preRoll(id: 'intro-ad'),
    ],
  ),
);
```

That is the whole integration. Everything below is reference material.

---

## 3. Declaring the tag list

### Option A — `vastWaterfall` (recommended)

The tag order is exactly the list you pass. The first entry also becomes the
primary `adTagUrl` sent with the content load.

```dart
NativeVideoPlayerAdConfiguration.vastWaterfall(
  required List<Uri> vastTags,
  bool enabled = true,
  List<NativeVideoPlayerAdBreak> adBreaks = const [],
  Duration? timeout,
  NativeVideoPlayerAdSkipConfiguration? skipConfiguration,
  NativeVideoPlayerAdRequestMetadata? requestMetadata,
  bool resumeContentOnError = true,
  Duration perTagTimeout = const Duration(seconds: 8),
)
```

An empty `vastTags` throws `ArgumentError`, so a missing list fails at the call
site instead of silently serving no ads.

### Option B — `vast` with `vastTags`

```dart
NativeVideoPlayerAdConfiguration.vast(
  required Uri adTagUrl,
  // ...all existing parameters...
  List<Uri> vastTags = const <Uri>[],
  Duration perTagTimeout = const Duration(seconds: 8),
  bool includeSingleTagAsFallback = false,
)
```

`adTagUrl` is always requested first; `vastTags` follow in order. This form is
useful when the primary tag is chosen dynamically and the fallbacks are static.

### Both forms are equivalent

```dart
// Option A
NativeVideoPlayerAdConfiguration.vastWaterfall(vastTags: [a, b, c])

// Option B — identical effective order
NativeVideoPlayerAdConfiguration.vast(adTagUrl: a, vastTags: [b, c])
```

---

## 4. Configuration reference

| Parameter                    | Type        | Default                | Applies to                      | Purpose                                                                                                                        |
| ---------------------------- | ----------- | ---------------------- | ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `vastTags`                   | `List<Uri>` | `const <Uri>[]`        | `vast`, `vastWaterfall`         | Ordered fallback tags requested after `adTagUrl`. Ignored for VMAP.                                                            |
| `perTagTimeout`              | `Duration`  | `Duration(seconds: 8)` | `vast`, `vastWaterfall`, `vmap` | Deadline for **each** tag. On expiry the tag counts as no fill and the waterfall advances. `Duration.zero` disables the timer. |
| `includeSingleTagAsFallback` | `bool`      | `false`                | `vast`                          | When `vastTags` is empty, retry the single `adTagUrl` once. Ignored when `vastTags` is non-empty.                              |

### Derived read-only getters

| Getter            | Type        | Description                                                               |
| ----------------- | ----------- | ------------------------------------------------------------------------- |
| `waterfallTags`   | `List<Uri>` | The effective ordered, de-duplicated list; always starts with `adTagUrl`. |
| `hasTagWaterfall` | `bool`      | `true` when more than one tag will be requested.                          |

```dart
final config = NativeVideoPlayerAdConfiguration.vastWaterfall(
  vastTags: <Uri>[a, b],
);

print(config.waterfallTags);  // [a, b]
print(config.hasTagWaterfall); // true
```

### Wire payload

`toMap()` always includes `perTagTimeoutMs`, and includes `vastTags` (string
URLs) and `includeSingleTagAsFallback` when they are non-default:

```dart
NativeVideoPlayerAdConfiguration.vastWaterfall(
  vastTags: <Uri>[a, b],
).toMap();
// {
//   'adTagUrl': 'https://ads.example.com/a.xml',
//   'tagType': 'vast',
//   'vastTags': ['https://ads.example.com/a.xml', 'https://ads.example.com/b.xml'],
//   'perTagTimeoutMs': 8000,
// }
```

---

## 5. Ordering rules

The effective order is deterministic:

1. `adTagUrl` is **always** the first tag, whichever constructor you use.
2. `vastTags` entries follow in the exact order you listed them.
3. Empty tag strings are skipped.
4. Duplicates are removed; the first occurrence wins.
5. When `vastTags` is empty and `includeSingleTagAsFallback` is `true`, the
   single tag is listed twice.

```dart
// Effective order → [primary, backup]
// (`primary` inside vastTags is dropped: it is already first)
NativeVideoPlayerAdConfiguration.vast(
  adTagUrl: Uri.parse('https://ads.example.com/primary.xml'),
  vastTags: <Uri>[
    Uri.parse('https://ads.example.com/primary.xml'),
    Uri.parse('https://backup.example.com/secondary.xml'),
  ],
);
```

**A tag that is listed only once is requested only once.** To retry the same
URL, either list a distinct URL or use `includeSingleTagAsFallback`.

---

## 6. When the waterfall advances

A tag is abandoned and the next one requested when it produces **no playable
ad**.

### No-fill error codes

| Code                        | Meaning                                                        |
| --------------------------- | -------------------------------------------------------------- |
| `VAST_EMPTY_RESPONSE`       | The VAST document contains no `<Ad>`                           |
| `VAST_NO_ADS_AFTER_WRAPPER` | A wrapper resolved to nothing                                  |
| `VAST_MEDIA_LOAD_TIMEOUT`   | The selected media never became playable                       |
| `AD_BREAK_FETCH_ERROR`      | IMA could not fetch the break                                  |
| `IMA_AD_LOAD_ERROR`         | IMA failed to load the ad                                      |
| `LOAD_ERROR`                | The ad server could not be reached                             |
| `IMA_AD_ERROR`              | IMA error treated as no fill when the message indicates no ads |
| `IMA_OPERATION_FAILED`      | Adapter operation failed (message-based)                       |
| `AD_PLAYER_ERROR`           | Ad media playback failed                                       |
| `AD_TAG_TIMEOUT`            | **The package's own per-tag timeout fired**                    |
| `AD_TAG_REQUEST_FAILED`     | The tag request could not be issued                            |

### Message-based classification

Any error whose message contains one of the following is treated as no fill,
even under an unknown code. This keeps the waterfall working across IMA SDK
versions that rename or reclassify errors:

- `no ad`
- `no fill`
- `empty vast`
- `no ads`
- `does not contain any ads`
- `vast response is empty`
- `no valid ad`

### Fatal errors

Errors that mean the **request itself** was malformed stop the waterfall rather
than pointlessly retrying the remaining tags. A VAST schema validation error is
the canonical example.

You can apply the same rule yourself:

```dart
final isNoFill = NativeVideoPlayerAdWaterfallManager.isNoFillError(
  const NativeVideoPlayerAdError(
    code: 'VAST_SCHEMA_VALIDATION_ERROR',
    message: 'The VAST document did not validate.',
  ),
);
print(isNoFill); // false
```

### Playback-time failures

A creative that fails **after** it was selected (for example the ad video URL
404s) also advances to the next tag, because that tag still could not deliver a
playable ad.

### The one exception

Once an ad has **actually started playing**, the waterfall is finished. A later
failure is a normal ad-session failure and does **not** restart the fallback
chain.

### Outcome matrix

| Current tag outcome                        | Waterfall action                                          |
| ------------------------------------------ | --------------------------------------------------------- |
| Loads an ad, ad starts playing             | Resolve; playback continues                               |
| Loads an ad, media fails during playback   | Advance to the next tag                                   |
| No fill (`VAST_EMPTY_RESPONSE`, …)         | Advance to the next tag                                   |
| Timeout (`AD_TAG_TIMEOUT`)                 | Advance to the next tag                                   |
| Fatal error (schema, invalid tag)          | Stop; break fails                                         |
| Fatal error, `continueOnFatalErrors: true` | Advance to the next tag                                   |
| Last tag fails                             | End with `waterfallExhausted`; content resumes by default |

---

## 7. Timeouts

`perTagTimeout` bounds **each tag individually**, not the whole break. A
three-tag waterfall with a 6s timeout can therefore take up to ~18s in the worst
case, where every server hangs until its deadline.

| Tags | `perTagTimeout` | Worst-case wait before content starts |
| ---- | --------------- | ------------------------------------- |
| 2    | 6s              | ~12s                                  |
| 3    | 6s              | ~18s                                  |
| 3    | 4s              | ~12s                                  |
| 3    | `Duration.zero` | Unbounded — provider callbacks only   |

A tag that fails **immediately** (a fast no-fill response) does not wait out the
timeout: the next tag is requested as soon as the error arrives, which is the
common case in production. The timeout exists for the slow/hanging server, not
the fast empty one.

```dart
// Tight budget: never hold the user for long.
perTagTimeout: const Duration(seconds: 3),
```

```dart
// Trust the provider's own callbacks entirely.
perTagTimeout: Duration.zero,
```

---

## 8. Observing the waterfall

### 8.1 Events (recommended)

Three event types are added to the existing ad event stream:

| Event                | Fields                                            | Meaning                        |
| -------------------- | ------------------------------------------------- | ------------------------------ |
| `tagRequested`       | `tagIndex`, `totalTags`, `adTagUrl`               | A tag is about to be requested |
| `tagFailed`          | `tagIndex`, `error`, `adTagUrl`                   | A tag was abandoned            |
| `waterfallExhausted` | `tagIndex`, `error`, `metadata.adSystem` → reason | Every tag failed               |

```dart
controller.advertisementController.events.listen((event) {
  if (event.type == NativeVideoPlayerAdEventType.waterfallExhausted) {
    final reason = event.metadata?.adSystem; // contains 'allTagsExhausted' / 'fatalError'
    print('waterfall ended: $reason');
  }
});
```

The stop reason is a `NativeVideoPlayerAdWaterfallStopReason`:

| Reason             | Meaning                                   |
| ------------------ | ----------------------------------------- |
| `allTagsExhausted` | Every tag reported no ad                  |
| `fatalError`       | A non-recoverable error stopped the chain |
| `cancelled`        | The session was cancelled or disposed     |

### 8.2 Live manager state

```dart
final ads = controller.advertisementController;

ads.waterfall           // NativeVideoPlayerAdWaterfallManager?, null when idle
ads.hasTagWaterfall     // bool — true only while a multi-tag run is in progress
ads.currentTagIndex     // int? — 0-based index being requested
ads.currentTags         // List<Uri> — ordered tags of the active run
```

Manager getters:

| Getter         | Type                                    | Description                                   |
| -------------- | --------------------------------------- | --------------------------------------------- |
| `isRunning`    | `bool`                                  | A waterfall is in progress                    |
| `currentIndex` | `int`                                   | 0-based index being requested, `-1` when idle |
| `currentTag`   | `Uri?`                                  | The tag being requested                       |
| `totalTags`    | `int`                                   | Number of tags in the active run              |
| `snapshot`     | `List<NativeVideoPlayerAdWaterfallTag>` | Per-tag state                                 |
| `events`       | `Stream<NativeVideoPlayerAdEvent>`      | Waterfall milestones                          |

### 8.3 Per-tag snapshot

```dart
for (final tag in ads.waterfall?.snapshot ?? const []) {
  print('${tag.index}: ${tag.url} → ${tag.state.name}'
      '${tag.error == null ? '' : ' (${tag.error!.code})'}');
}
```

`NativeVideoPlayerAdWaterfallTag` fields: `url`, `index`, `state`, `error`,
`isRequesting`.

`NativeVideoPlayerAdWaterfallTagState` values:

| State        | Meaning                               |
| ------------ | ------------------------------------- |
| `pending`    | Not requested yet                     |
| `requesting` | Currently being requested and awaited |
| `filled`     | Returned a playable ad                |
| `noFill`     | Reported no ad or timed out           |
| `failed`     | Reported a non-recoverable error      |

---

## 9. Observer callbacks (advanced)

Use this when you drive the manager yourself, or prefer callbacks over streams.

```dart
final waterfall = NativeVideoPlayerAdWaterfallManager(
  // Ask the native adapter to request a tag. Must not throw.
  requestTag: (config) async => myAdapter.request(config.adTagUrl),

  // Tear down the previous attempt: destroy the AdsManager, keep the
  // AdsLoader. Called before the next tag is requested.
  onTagAbandoned: () async => myAdapter.destroyCurrentAdsManager(),

  // false (default) = a schema error ends the waterfall.
  // true = keep advancing past any error.
  continueOnFatalErrors: false,

  callbacks: const NativeVideoPlayerAdWaterfallCallbacks(
    onTagRequested: (tag, index, total) =>
        print('trying ${index + 1}/$total: $tag'),
    onTagFilled: (tag, index) => print('$tag returned an ad'),
    onTagFailed: (tag, index, error, next) =>
        print('$tag failed (${error.code}); next=${next ?? 'none'}'),
    onAdStarted: (tag, index) => print('ad playing from $tag'),
    onAllTagsFailed: (reason) => print('waterfall ended: ${reason.name}'),
  ),
);

waterfall.events.listen((event) => print('event: ${event.type}'));
waterfall.start(configuration);

// When the ad session ends:
await waterfall.dispose();
```

### Callback reference

| Callback          | Signature                                                                           |
| ----------------- | ----------------------------------------------------------------------------------- |
| `onTagRequested`  | `void Function(Uri tag, int index, int total)`                                      |
| `onTagFilled`     | `void Function(Uri tag, int index)`                                                 |
| `onTagFailed`     | `void Function(Uri tag, int index, NativeVideoPlayerAdError error, int? nextIndex)` |
| `onAdStarted`     | `void Function(Uri tag, int index)`                                                 |
| `onAllTagsFailed` | `void Function(NativeVideoPlayerAdWaterfallStopReason reason)`                      |

### Driving the manager directly

| Method                        | Purpose                                                                                                         |
| ----------------------------- | --------------------------------------------------------------------------------------------------------------- |
| `bool start(configuration)`   | Begin the run. Returns `false` when there is no tag or the manager is disposed. Cancels any previous run first. |
| `void onTagLoaded()`          | The current tag returned an ad (playback not necessarily started).                                              |
| `void onAdStarted()`          | An ad actually started; resolves the waterfall.                                                                 |
| `bool onTagNoFill(error)`     | The current tag produced no ad; advances if tags remain. Returns `true` when another tag was requested.         |
| `bool onTagFailed(error)`     | Provider error; advances only for no-fill codes unless `continueOnFatalErrors`.                                 |
| `bool onPlaybackError(error)` | Media error after `ready`; still advances to the next tag.                                                      |
| `void cancel({reason})`       | Stop the run without a terminal event. A late native event is ignored.                                          |
| `Future<void> dispose()`      | Release the manager and its stream. Safe to call more than once.                                                |
| `set callbacks(...)`          | Replace the callback set.                                                                                       |

> **Note:** when you use `adConfiguration` through
> `NativeVideoPlayerController.load`, the controller creates and owns the
> manager. You do not need to construct one. The manual construction above is for
> custom adapters and for unit tests.

---

## 10. How it crosses the native bridge

The waterfall does not fight IMA's design:

- The **`AdsLoader` is created once per content load and reused** for every tag.
- Before requesting the next tag, the previous **`AdsManager` is destroyed**, so
  only one manager is ever alive. This is why the callbacks include
  `onTagAbandoned`.
- `adTagUrl` is the only value that changes between requests. The `adBreaks`
  schedule, skip policy, request metadata, and `resumeContentOnError` stay
  identical across fallbacks.
- Waterfall logic is pure Dart and unit-tested without a device; the native
  adapters require no changes.

Internally, the controller's `requestAdvertisements()` routes:

| Configuration                        | Path                                             |
| ------------------------------------ | ------------------------------------------------ |
| One tag (`hasTagWaterfall == false`) | Original single `initialize` + `request`         |
| More than one tag                    | `NativeVideoPlayerAdWaterfallManager.start(...)` |

---

## 11. Compatibility

| Scenario                                        | Behavior                                                |
| ----------------------------------------------- | ------------------------------------------------------- |
| Single tag, `includeSingleTagAsFallback: false` | Exactly one request — identical to the previous release |
| Single tag, `includeSingleTagAsFallback: true`  | Same tag requested up to twice                          |
| VMAP                                            | `vastTags` ignored; the VMAP schedule is authoritative  |
| Pre-roll                                        | Waterfall supported                                     |
| Mid-roll(s)                                     | Waterfall supported; each break runs its own waterfall  |
| Post-roll                                       | Waterfall supported                                     |
| `load(..., force: true)` / reload               | Fresh waterfall; any in-flight run is cancelled         |
| `releaseResources()` / `dispose()`              | Waterfall cancelled and disposed with the ad session    |
| Texture mode / desktop / web                    | No native IMA adapter, so no ads (unchanged)            |

A break-level `NativeVideoPlayerAdBreak.adTagUrl` override is **not** part of
the waterfall: the ordered list on the configuration is authoritative.

---

## 12. Cookbook

### Pre-roll with three ad networks

```dart
adConfiguration: NativeVideoPlayerAdConfiguration.vastWaterfall(
  vastTags: <Uri>[networkA, networkB, networkC],
  perTagTimeout: const Duration(seconds: 5),
  adBreaks: const <NativeVideoPlayerAdBreak>[
    NativeVideoPlayerAdBreak.preRoll(id: 'pre'),
  ],
)
```

### Mid-roll fallback at 10 and 20 minutes

Each break runs its own waterfall with the same ordered tag list.

```dart
adConfiguration: NativeVideoPlayerAdConfiguration.vastWaterfall(
  vastTags: <Uri>[networkA, networkB],
  adBreaks: const <NativeVideoPlayerAdBreak>[
    NativeVideoPlayerAdBreak.midRoll(
      id: 'break-10m',
      position: Duration(minutes: 10),
    ),
    NativeVideoPlayerAdBreak.midRoll(
      id: 'break-20m',
      position: Duration(minutes: 20),
    ),
  ],
)
```

### Retry the same tag once (no second URL)

```dart
adConfiguration: NativeVideoPlayerAdConfiguration.vast(
  adTagUrl: Uri.parse('https://ads.example.com/tag.xml'),
  includeSingleTagAsFallback: true,
  adBreaks: const <NativeVideoPlayerAdBreak>[
    NativeVideoPlayerAdBreak.preRoll(id: 'pre'),
  ],
)
```

### Never let ads delay content indefinitely

```dart
adConfiguration: NativeVideoPlayerAdConfiguration.vastWaterfall(
  vastTags: <Uri>[networkA, networkB, networkC],
  perTagTimeout: const Duration(seconds: 3), // ~9s worst case
  adBreaks: const <NativeVideoPlayerAdBreak>[
    NativeVideoPlayerAdBreak.preRoll(id: 'pre'),
  ],
)
```

### Show “Ad source N of M” in your own UI

```dart
StreamBuilder<NativeVideoPlayerAdEvent>(
  stream: controller.advertisementController.events,
  builder: (context, snap) {
    final event = snap.data;
    if (event?.type != NativeVideoPlayerAdEventType.tagRequested) {
      return const SizedBox.shrink();
    }
    final attempted = (event!.tagIndex ?? 0) + 1;
    return Text('Ad source $attempted of ${event.totalTags}');
  },
)
```

### Log every fallback for analytics

```dart
controller.advertisementController.events.listen((event) {
  if (event.type == NativeVideoPlayerAdEventType.tagFailed) {
    analytics.log('ad_tag_failed', {
      'index': event.tagIndex,
      'total': event.totalTags,
      'code': event.error?.code,
      'url': event.adTagUrl?.toString(),
    });
  }
  if (event.type == NativeVideoPlayerAdEventType.waterfallExhausted) {
    analytics.log('ad_waterfall_exhausted', {
      'reason': event.metadata?.adSystem,
    });
  }
});
```

---

## 13. Troubleshooting

| Symptom                                       | Likely cause                                                           | Fix                                                                        |
| --------------------------------------------- | ---------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| Only the first tag is requested               | `vastTags` empty, or the list collapsed to one entry by de-duplication | Print `configuration.waterfallTags` and confirm it has more than one entry |
| Fallback happens immediately on every request | The primary tag returns a plain no-fill code                           | Intended behavior — the waterfall is working                               |
| A schema error stops the chain                | Fatal errors end the waterfall by default                              | Fix the malformed tag, or use `continueOnFatalErrors: true`                |
| Content takes too long to start               | `perTagTimeout` × number of tags is the worst case                     | Lower `perTagTimeout`, or use fewer tags                                   |
| `waterfall` is null                           | The run already resolved, or the configuration has one tag             | Check `hasTagWaterfall`; single-tag runs keep the original path            |
| No waterfall events at all                    | Subscribed after `load()`                                              | Subscribe to `events` before calling `load()`                              |
| A tag seems to be requested twice             | `includeSingleTagAsFallback: true` with an empty `vastTags`            | That flag retries the primary tag once by design                           |
| Ads never appear, no events                   | Ads disabled, unsupported platform, or texture mode                    | See the README's “Getting Ads Working Without Errors”                      |

---

## 14. Testing your waterfall configuration

The configuration getters make the ordering rules easy to assert without a
device:

```dart
test('primary tag leads the waterfall and duplicates are dropped', () {
  final config = NativeVideoPlayerAdConfiguration.vast(
    adTagUrl: Uri.parse('https://ads.example.com/primary.xml'),
    vastTags: <Uri>[
      Uri.parse('https://ads.example.com/primary.xml'),
      Uri.parse('https://backup.example.com/secondary.xml'),
    ],
  );

  expect(config.waterfallTags, <Uri>[
    Uri.parse('https://ads.example.com/primary.xml'),
    Uri.parse('https://backup.example.com/secondary.xml'),
  ]);
  expect(config.hasTagWaterfall, isTrue);
});
```

The package's own waterfall test suite lives in
[`test/advertising_waterfall_test.dart`](../test/advertising_waterfall_test.dart)
and drives `NativeVideoPlayerAdWaterfallManager` directly with a fake
`requestTag`, covering ordering, no-fill advancement, timeouts, fatal errors,
cancellation, and the per-tag snapshot.
