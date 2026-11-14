# Native motion review

Use the existing app flow and cached decoder. This directory holds capture/review
support, not a second UI implementation or a separate app target.

## Current path

1. Build the ordinary app with `python3 tools/dev.py build`.
2. Run the matching existing `native-check` flow. Recording flags are
   feature-specific; `--motion` is not accepted for every flow. Use the command's
   help rather than adding it to an unrelated check. For example, the generated
   SMB transfer-menu flow records its admitted Move dialog itself.
   The generated Help/operation-log flow also records diagnostic-size pages:
   `python3 tools/distribution/qualify_help_diagnostics.py --record-motion`.
   Shared Settings/Help/Drives flows can use the same current Debug app through
   `python3 -B tools/development.py motion --surface tools --ordinary-app`.
   Add `--large --light` or `--mode reduced` to inspect those preferences.
3. Decode retained recordings without reopening the app:

   ```sh
   python3 tools/ui_motion/review_current.py CASE-UUID --review-id short-label
   ```

4. Inspect the dense action frames, settled image and relevant detail crops.
   Read the native result and decoded timing/geometry together. A successful
   decoder run does not establish that an operation or server flow passed.

`review_current.py` compiles `review_development.swift` only when its source or
cached binary changes. The one decoder and compiler receipt stay under
`.build/ui-motion/`; existing compiler caches are reused. Each review references
the original movie and capture metadata. It synthesizes no frames and does not
request screen access or start a live capture. Use a new short review ID to
preserve an earlier review's evidence.

For an existing failed Settings, analysis or Help capture, `--forensic` decodes
only its retained declared clips. It never marks native acceptance, repairs a
failure receipt or starts another app/capture. Inspect useful frames before
deciding whether another native run is needed.

## Files and boundaries

| File | Responsibility |
| --- | --- |
| `run_development.py` | Runtime-only implementation behind the stable `development.py motion` command; binds its own/controller source separately from compiled app/build inputs |
| `review_current.py` | Supported cached all-delivered-frame review entry point for the admitted native flows |
| `review_development.swift` | Sequential native video decode, geometry/timing, optional field luminance, contact sheets and settled/detail images |
| `review.swift`, `review.py` | Earlier bounded sampled-frame review used by the historical network experiments |
| `review_*.swift`, `review_*.py` | Retained feature-specific reviewers; extend the current decoder for new ordinary flows rather than adding another one-off reviewer |
| `replay.*`, `qualify_replay.py` | Generated replay review, separate from real native-window evidence |
| `temporal_coverage.py`, `test_bounds.py` | Existing timing/size-bound checks; run when those contracts change |

The app's `Development/Checks/NativeMotionRecorder.swift` owns actual capture.
It records only admitted generated windows in its own process, with no audio or
whole-display capture. Normal app startup has no recorder. A locked console or
missing capture permission is a dependency, not a rendering failure.

Diagnostic capture requests120fps with a finite180-frame ceiling; delivered
timestamps, gaps and encoder drops describe the actual recording. Do not report
the requested rate as observed delivery. The frozen page-step metric applies to
real page/device transitions, not disclosure expansion, scrolling or a no-op
refresh. A field-black metric is meaningful only when its field region exists;
otherwise inspect the field in the authentic images without claiming a measured
field verdict.
When a native capture explicitly observes that a field did not exist before the
action, revision7 keeps its raw luminance/dark-area measurements and contact
sheets but labels the field verdict visual-only. An empty pre-creation region
cannot establish a field flicker. Existing captures without that observation
retain their original black-field gate; no threshold or frame is discarded.

The current Help diagnostic route uses that geometry-checked120fps request,
not the older fixed960×640/60fps letterboxed capture. Its four owned page movies
share the same cached decoder as the development flows. Historical sampled Help
reviewers remain evidence tools and do not establish current capture geometry.

Keep one useful current recording per changed flow and compact unresolved-failure
evidence under the engineering retention policy. Reuse an existing movie for a
decoder correction instead of recording the same interaction again.
