# SlimKit Implementation Plan

## Current state

The repository contains the native macOS app scaffold, Photos browser, conservative resource classifier, verified-size domain and cache, rolling file logs, and command-line build/test targets. Compression, import verification, and deletion are not implemented. This plan stages the remaining work with safety and technical validation ahead of destructive workflows.

## Guiding constraints

- Use Swift 5.9+, SwiftUI, PhotoKit, SwiftData, and target macOS 14+ as specified.
- Never modify the Photos library package directly.
- Treat uncertain asset eligibility, size, import, or deletion state as a reason to stop and require review.
- Keep originals until a replacement is imported, independently verified, and the user explicitly approves deletion.
- Clearly distinguish compression reduction, potential library reduction, and confirmed reclaimed storage.

## Milestones

### 0. Technical validation and project setup

- [x] Confirm available macOS/Xcode/Swift toolchain and create the native macOS app project.
- [ ] Validate PhotoKit authorization behavior, resource enumeration/export, import verification, and deletion APIs for the deployment target. Authorization, fetching, thumbnail, and selected-resource export APIs compile; live resource export, import, and deletion remain unvalidated.
- [ ] Confirm App Sandbox and Photos permission configuration for the intended distribution method. Initial sandbox and Photos entitlement are configured; distribution-specific validation remains.
- [ ] Record API limitations and adjust implementation details without weakening the safety requirements.
- [x] Establish app target, build settings, and a SwiftUI browser shell; launch/runtime behavior remains to be smoke-tested.

**Exit criteria:** The app builds and launches on macOS 14+, and the selected public APIs support the planned safe workflow.

### 1. Architecture and domain foundations

- [ ] Define domain models for media, size state, capabilities, compression jobs/results, durable phases, and typed errors.
- [ ] Define service protocols for Photos access, scanning, thumbnails, compression, validation, persistence, and mutations.
- [ ] Add SwiftData persistence for review state, size cache, operation history, and recovery checkpoints.
- [ ] Keep PhotoKit objects out of persisted and domain models; use asset identifiers at service boundaries.
- [x] Add a unit-test target and establish a focused XCTest convention.

**Exit criteria:** Core models and workflow state transitions are testable without SwiftUI or a real Photos library.

### 2. Authorization and non-destructive Photos browser

- [ ] Implement authorization states and the user-initiated connect flow.
- [ ] Handle denied, restricted, limited/restricted-access, revoked, and insufficient write-access states with clear guidance.
- [ ] Fetch accessible photo and video assets and observe library changes.
- [ ] Build lazy, cancellable thumbnail loading and memory-aware caching.
- [ ] Implement sidebar navigation, media grid, filters, sorting, keyboard selection, preview, and status display.
- [ ] Implement Keep as app-only review state, with a way to restore kept assets to active browsing.

**Exit criteria:** The user can browse accessible media responsively; browsing does not download full originals or modify Photos assets.

### 3. Eligibility and trustworthy size discovery

- [ ] Inspect PhotoKit resources and asset subtypes to classify supported, unsupported, pending, and uncertain media.
- [ ] Detect edited assets, Live Photos, paired/ambiguous resources, animation, auxiliary data, HDR/wide-gamut features, and unsupported video tracks/features where possible.
- [ ] Treat uncertain classification as ineligible; expose a user-readable skip reason.
- [ ] Implement progressive size discovery without downloading the whole library for sorting.
- [ ] Count bytes only after complete export of the selected source payload; otherwise show estimated, unknown, or unavailable.
- [ ] Cache verified sizes with resource-selection basis and source modification state; invalidate stale entries after relevant library changes.
- [ ] Support scan progress, cancellation, and bounded work.

**Exit criteria:** The browser never labels estimates as exact and can explain why an asset is not eligible for compression.

### 4. Compression engine and local job queue

- [ ] Define the three presets as explicit codec, quality, dimension, and compatibility policies without promising a ratio.
- [ ] Create isolated per-operation temporary workspaces and check available disk space.
- [ ] Implement the image pipeline: export, inspect, encode, validate decode/dimensions/orientation/color policy, compare verified sizes.
- [ ] Implement the video pipeline: export, inspect tracks, encode supported SDR media, and validate duration, dimensions, orientation, and audio/video tracks.
- [ ] Reject unsupported properties, failed validations, non-smaller outputs, and source changes; apply the 5% minimum only when both byte counts are verified.
- [ ] Implement bounded scheduling: one video encode, limited image work and iCloud downloads, cancellation between phases, and progress reporting.
- [ ] Clean up successful temporary workspaces and retain/reconcile artifacts needed for recovery.

**Exit criteria:** Compression produces a structured result only for validated eligible media; no Photos changes occur in this milestone.

### 5. Results, import, and independent verification

- [ ] Build a results review showing source/output sizes, reduction, format/codec, dimensions, preset, and known metadata changes.
- [ ] Report batch success, failure, skip, unchanged, and size-unverified outcomes separately.
- [ ] Import only validated output with public PhotoKit change requests and supported metadata restoration.
- [ ] Persist the replacement identifier and workflow checkpoint as soon as available.
- [ ] Re-fetch the replacement and verify media type, dimensions, video duration (within one frame), resource readability, and byte count against the validated output.
- [ ] Verify selected creation date and location preservation; treat mismatches as verification failures.
- [ ] Keep the original intact if import or any required verification is pending or fails.

**Exit criteria:** A replacement is considered verified only after all required independent checks pass; import callback success alone is insufficient.

### 6. Explicit original deletion and recovery

- [ ] Present a separate deletion confirmation explaining unsupported edit/relationship preservation, Recently Deleted, and iCloud synchronization/storage behavior.
- [ ] Immediately before deletion, re-fetch and re-check both source and replacement, source eligibility, and source identity/state.
- [ ] Prevent deletion when source size is unverified, source changed, access is insufficient, or replacement verification is uncertain.
- [ ] Delete only through PhotoKit change requests and record transaction outcome without claiming reclaimed storage.
- [ ] Implement restart recovery and reconciliation for every durable workflow phase, including uncertain import/deletion outcomes.
- [ ] Mark unresolved cases Needs Review; never blindly duplicate an import or delete the source during recovery.

**Exit criteria:** Deletion is explicit, independently gated, auditable, and safe under interruption or uncertain outcomes.

### 7. Hardening and release readiness

- [ ] Add unit tests for classification, eligibility, size and savings math, preset policy, state transitions, cancellation, error mapping, and recovery.
- [ ] Add integration tests using a dedicated test Photos library; never run destructive tests against a personal library.
- [ ] Exercise the safety scenarios in `SPEC.md`, especially crashes, source changes, verification failure, permission changes, disk exhaustion, and uncertain deletion.
- [ ] Test representative supported/unsupported media from the compatibility matrix and document proven limits.
- [ ] Profile 1k, 10k, 50k, and 100k asset libraries for responsiveness, memory, thumbnail behavior, and temporary-file cleanup.
- [ ] Verify privacy, sandbox, permission strings, actionable errors, and user-facing storage terminology.

**Exit criteria:** Safety tests pass, supported media behavior is documented, performance has been measured, and no workflow reports unverified savings or reclaimed storage.

## Progress

- **Foundation/browser slice — in progress:** Added an XcodeGen macOS app target, Photos read/write authorization flow and foreground recheck, observed/debounced library refresh, batched asset enumeration, lazy cancellable thumbnails, photo/video preview, filters, multi-selection, persistent Keep/restore state, and explicit unknown size labels. Limited access is labeled as limited. Preview error 3164 now explains iCloud availability and requires confirmation before network access; the request has progress and cancellation controls. After adding the sandbox outgoing-network entitlement, a user-confirmed iCloud video reached AVPlayer ready state and reported a 21.77-second duration.
- **Resource-size slice — in progress:** Added a user-confirmed selected-item export, fail-closed single-resource/subtype selection, streamed writes to temporary files, exact file-size versus streamed-byte verification, source re-fetch/modification-state check, cancellation, cleanup, and persistent verified-size records keyed by modification date and resource-selection basis. One user-confirmed iCloud video export completed and verified 2,332,638 bytes. Items without a modification date are conservatively unavailable. Full HDR/color/depth and video-track capability inspection is not implemented.
- **Domain safety slice — in progress:** Added verified-versus-estimated size states, preset and durable phase identifiers, savings assessment, deletion precondition gate, and conservative resource/subtype eligibility classification. Nine XCTest cases cover size math, eligibility, cancellation, source/cache validity, and deletion gates. The deletion gate is not connected to a Photos mutation workflow.
- **Build/test evidence:** `make test` passed with 9 tests, `make build` succeeded, SwiftLint and `git diff --check` passed, and `codesign --verify --deep --strict` passed. One live, user-confirmed iCloud video preview reached AVPlayer ready state; cancellation and broader Photos authorization behavior still need testing.
- **Not implemented:** Full source capability inspection, repeatable Photos export integration tests, compression, import verification, Photos deletion, restart recovery, and dedicated test-library coverage. A crash after live video preview was traced to SwiftUI AVKit `VideoPlayer` and replaced with AppKit `AVPlayerView`. AVPlayer readiness and failures are now logged and shown. Adding outbound sandbox networking resolved the observed iCloud hostname failure in one live preview; more playback and cancellation coverage is needed.

## Investigation update

- The initial asset model called `PHAssetResource.assetResources(for:)` for every media item while constructing the entire library array. Because the browser waited for the full array before showing items, the repeated per-asset resource inspection was a likely cause of the prolonged loading state. The initial browser scan now collects only lightweight asset metadata and defers eligibility inspection.
- Library scans now publish batches of 1,000 assets and show scan progress. Foreground activation no longer restarts a scan when Photos authorization is unchanged.
- Added file and unified logging for launch, authorization, scan/query/enumeration timing and progress, library change notifications, thumbnail requests/errors, and Keep actions. Rolling files are stored under `~/Library/Logs/SlimKit/` (`SlimKit.log` plus five 1 MiB rotations).
- Current instrumented run: 23,033 assets fetched; PhotoKit fetch query rounded to 0 seconds; enumeration completed in about 1 second. Four visible thumbnail requests logged PhotoKit error 3164; those requests remain placeholders and did not prevent the scan from completing.
- The requested log path is outside the app sandbox container. A narrowly scoped home-relative sandbox exception grants writes only to `/Library/Logs/SlimKit/`.

## Next implementation phase

1. Test iCloud preview cancellation and failure handling, plus local photo/video previews. The error-3164 consent flow and network-enabled playback have each succeeded once; repeat with a dedicated Photos test library.
2. Extend capability inspection beyond subtype/resource count, especially for HDR, wide gamut, depth/auxiliary image data, and video tracks. Treat uninspected media as not eligible for compression.
3. Repeat selected-resource tests against local and iCloud-only assets, including cancellation, failures, temporary cleanup, and cache invalidation. One iCloud video export completed; repeatable integration coverage remains absent. The exporter fails closed when the source modification date is unavailable.
4. Do not start compression until capability inspection and size-discovery exit criteria pass. Keep Photos import, replacement verification, and deletion out of this phase.

## Initial implementation order

1. Complete Milestone 0 and capture any API constraints.
2. Implement domain foundations and testable state transitions.
3. Deliver the read-only browser and honest size states.
4. Add eligibility and compression without Photos mutation.
5. Add import verification, then explicit deletion and recovery.
6. Finish with compatibility, safety, and scale testing.
