# RFC-001 — SlimKit: Apple Photos Integration

**Status:** Proposed  
**Product name:** SlimKit  
**Repository slug:** slim-kit  
**Version:** 1.0  
**Created:** November 7, 2026  
**Target platform:** macOS 14+  
**Implementation:** Swift 5.9+, SwiftUI, PhotoKit  
**Scope:** Apple Photos — Photos and Videos  
**Document owner:** Engineering  
**Review status:** Pending technical validation

---

## 1. Executive Summary

SlimKit is a native macOS application designed to reduce the storage consumed by photos and videos in Apple Photos.

The application will scan a user's Photos library, display media in a visual browser, identify large assets, and allow users to compress selected photos and videos using configurable quality settings.

All compression will run locally on the user's Mac.

The application will integrate with Apple Photos through Apple's public PhotoKit APIs. It will respect Photos permissions, iCloud synchronization, user edits, and library ownership.

### Primary objectives

1. Help users understand which photos and videos consume the most storage.
2. Provide high-quality compression for supported image and video formats.
3. Make compression easy through single-item and batch workflows.
4. Preserve originals unless the user explicitly approves their deletion.
5. Maintain an auditable history of compression operations.
6. Provide accurate compression statistics and clearly distinguish estimated savings from reclaimed storage.

### Product principle

**No original media should be deleted until a valid compressed replacement has been created, imported into Photos, verified, and explicitly approved by the user.**

---

## 2. Problem Statement

Apple Photos libraries can become very large because of:

- 4K and high-frame-rate videos.
- Photos captured at high resolution.
- Large PNG, TIFF, and other image formats.
- ProRes and other high-bitrate video formats.
- Repeated or unnecessary media.
- Original media retained by iCloud Photos.

Although Apple Photos provides organization and storage optimization features, it does not offer a dedicated workflow for systematically discovering large media files and replacing them with smaller, user-approved versions.

Users need a tool that makes storage reduction understandable, measurable, and safe.

### Target users

- Mac users with large Apple Photos libraries.
- Users storing many high-resolution videos.
- Users paying for additional iCloud storage.
- Photographers wanting smaller sharing or archival copies.
- Users seeking selective compression instead of indiscriminately reducing library quality.

### Primary user story

As a user with a large Apple Photos library, I want to see my largest photos and videos, compress selected items, compare their sizes, and safely remove originals so that I can reduce storage consumption without accidentally losing important media.

---

## 3. Scope

### 3.1 Included in MVP

**Photos library**

- PhotoKit permission handling.
- Fetch photos and videos.
- Thumbnail generation.
- File size discovery.
- Library statistics.
- Incremental scanning and caching.
- Sort by file size, date, and duration.
- Filter media by type and status.
- Preview photos and videos.

**Compression**

- JPEG, HEIC, PNG, and selected other supported still-image inputs.
- H.264 and HEVC video encoding.
- Three compression presets.
- Batch compression.
- iCloud original downloads.
- Compression progress and cancellation.
- File integrity and media validation.
- Compressed asset import into Photos.
- Original deletion after separate confirmation.

**Application**

- Native SwiftUI interface.
- Sidebar navigation.
- Selectable media grid.
- Compression queue.
- Persistent operation history.
- Savings statistics.
- Settings and error reporting.

### 3.2 Deferred features

- RAW photo compression and RAW+JPEG pair management.
- Live Photo replacement.
- Preservation of complex nondestructive edit stacks.
- ProRes-specific advanced workflows.
- HDR and Dolby Vision preservation guarantees.
- Cinematic, spatial, depth, and portrait-effect asset processing.
- Duplicate and similarity detection.
- Automatic compression schedules.
- Compression based on machine-learning quality scores.
- Google Drive and standalone local folder integration.
- Multi-device coordination.
- Automatic deletion without confirmation.

### 3.3 Excluded from MVP processing

Unsupported or complex assets will remain visible in the library browser but will not be compressible.

The application must explain why an item is unsupported rather than silently omitting it.

---

## 4. Functional Requirements

### FR-001 — Photos Authorization

The application shall request read/write access to Apple Photos.

Requirements:

- Check the current PhotoKit authorization state.
- Explain access requirements before the system prompt.
- Request authorization when the user selects "Connect Apple Photos."
- Support authorized, denied, restricted, and not-determined states.
- Handle supported restricted-access modes without implying full-library visibility.
- Provide instructions for changing permissions in macOS Settings.
- Re-check authorization when returning to the foreground.
- Prevent writes if authorization is insufficient.

**Acceptance criteria:** The application never attempts to scan or modify inaccessible Photos assets.

### FR-002 — Library Scanning

The application shall enumerate accessible photo and video assets using PhotoKit.

For each asset, collect:

- PhotoKit local identifier.
- Media type.
- Creation date.
- Modification date.
- Pixel width.
- Pixel height.
- Video duration.
- Favorite status.
- Relevant media subtypes.
- Resource information where available.

File size discovery shall be implemented separately because a lightweight PhotoKit asset fetch does not reliably provide authoritative resource byte counts. A reported size represents the byte count of the selected source payload used for compression, not the total storage footprint of the Photos library asset. The selected payload is the original still-image or video resource for eligible assets; Photos thumbnails, cached derivatives, and unrelated library overhead are excluded.

A size is verified only when the complete selected payload has been exported and its bytes counted. Otherwise, show an estimate or unknown state. The scanner shall support progressive discovery, cancellation, and cached results.

**Acceptance criteria:** Initial thumbnails appear without requiring every full-resolution resource to be downloaded.

### FR-003 — File Size Analysis

The application shall provide exact size values when verified and clearly identified estimates otherwise.

Size discovery shall:

- Inspect available asset resource information.
- Avoid relying on undocumented PhotoKit properties.
- Avoid downloading an entire iCloud library solely to generate a size-sorted grid.
- Use supported resource export or streaming mechanisms when authoritative byte counts are required.
- Cache verified byte counts together with the resource-selection basis and asset modification state.
- Invalidate stale values after relevant library changes.
- Never compare a size estimate with a verified output size as an exact savings result.

When a reliable size is not available, the UI shall show "Size not calculated" or "Estimated."

**Acceptance criteria:** The app never presents fabricated or unverified file sizes as exact measurements.

### FR-004 — Media Browser

The main browser shall support:

- Adaptive thumbnail grid.
- Photo and video identification.
- Video duration badges.
- File size labels.
- Creation dates.
- Multi-selection.
- Keyboard navigation.
- Context menus.
- Large media preview.
- Sort by largest first.
- Filter by photos, videos, and reviewed status.

Photos shall use cached thumbnail requests to avoid decoding every original asset.

### FR-005 — Compression Presets

The application shall provide three presets:

| Preset | Objective | Initial strategy |
|---|---|---|
| High Quality | Minimize visible quality loss | Conservative encoding and resolution preservation |
| Balanced | Good quality with useful savings | Modern codecs and moderate quality settings |
| Maximum Savings | Prioritize smaller files | More aggressive encoding and optional downscaling |

Compression presets will be defined by codec, quality, size constraints, and supported media capabilities.

Preset names shall not imply a guaranteed compression ratio.

### FR-006 — Image Compression

The image compressor shall:

1. Retrieve a supported source image.
2. Decode the image using supported APIs.
3. Inspect dimensions, orientation, colorspace, and metadata.
4. Select a compatible output format.
5. Apply compression and optional resizing.
6. Write a temporary output file.
7. Validate that the result can be decoded.
8. Compare output size against source size.
9. Reject outputs that fail quality or safety constraints.

Initial output format selection:

- JPEG for compatible SDR images when requested.
- HEIC for compatible images when supported by the runtime and encoder.
- Preserve PNG where transparency or lossless requirements make conversion inappropriate.

Animated images, depth information, wide-gamut color, HDR, and auxiliary image data must receive explicit capability checks. Photos edit adjustments, paired RAW+JPEG resources, and assets with multiple still-image resources must also be detected before compression.

If these properties cannot be preserved acceptably, compression must be skipped. The MVP shall not offer a warning-based override for properties whose loss could not be reliably described or validated.

### FR-007 — Video Compression

The video compressor shall:

1. Retrieve the video resource.
2. Inspect source tracks and encoding properties.
3. Identify a supported export configuration.
4. Select H.264 or HEVC output.
5. Encode into a temporary file.
6. Preserve playable audio where supported.
7. Validate output duration, tracks, and dimensions.
8. Compare original and compressed file sizes.
9. Return a structured compression result.

Initial video handling:

- Support common SDR QuickTime and MP4 files.
- Prefer preserving source resolution for the High Quality preset.
- Permit optional downscaling for more aggressive presets.
- Preserve frame rate where feasible.
- Handle rotation and orientation.
- Explicitly validate audio retention.
- Report unsupported or incompatible formats.

HDR, advanced metadata, timed metadata, subtitles, multiple video or audio tracks, spatial/cinematic media, and other complex cases shall be treated as unsupported unless verified by dedicated tests. Assets with Photos edit adjustments or multiple candidate source video resources are ineligible in the MVP.

### FR-008 — Compression Preview

Before applying destructive actions, display:

- Original file size.
- Compressed file size.
- Percentage reduction.
- Output codec or format.
- Output resolution.
- Quality preset.
- Any known metadata changes.

For a batch, provide a summary of successfully processed, failed, skipped, and unchanged items.

**Acceptance criteria:** A compressed file that is not smaller than its original is never presented as a successful storage-saving result.

### FR-009 — Batch Compression

Users shall be able to select multiple assets and submit them to a processing queue.

The queue shall support:

- Pending.
- Downloading.
- Compressing.
- Validating.
- Importing.
- Awaiting user approval.
- Completed.
- Skipped.
- Failed.
- Cancelled.

The application shall not launch unrestricted concurrent encoding jobs.

Initial policy:

- One active video encode.
- Limited image compression concurrency.
- Bounded simultaneous iCloud downloads.
- Memory-aware scheduling.
- Cancellation between workflow phases.

### FR-010 — Compressed Asset Import

Successfully compressed output shall be imported through PhotoKit change requests.

The application shall:

- Create an appropriate new photo or video asset.
- Capture the resulting Photos asset identifier.
- Preserve supported creation date, location, and other selected metadata.
- Attempt to retain applicable album associations.
- Record any metadata that could not be preserved.
- Verify that the imported asset is retrievable and matches the validated output.

The MVP shall not claim to preserve Photos editing history or advanced asset relationships. Assets with edit adjustments are ineligible for compression and deletion in the MVP.

### FR-011 — Original Deletion

Original deletion shall occur only after:

- Compression completed successfully.
- Output file validation passed.
- Compressed import succeeded.
- The imported asset passed the independent verification checks in Section 9.3.
- The source asset is still the same eligible asset inspected at job start.
- The user explicitly approved deletion of the original asset after being told that Photos edits and unsupported relationships are not preserved.

Deletion shall use PhotoKit library change requests.

The application shall not directly manipulate the Photos library package.

The UI shall explain that deleted Photos assets may enter Recently Deleted and that actual space reclamation may be delayed.

### FR-012 — Keep Action

The Keep action shall mark an asset as reviewed inside the application's own database.

Keep shall not modify or hide an asset in Apple Photos.

A kept asset may be restored to the active scanning list at any time.

### FR-013 — Compression History

Every attempted operation shall maintain a durable history entry containing:

- Operation ID.
- Source asset ID.
- Replacement asset ID, if available.
- Media type.
- Source and output sizes.
- Compression preset.
- Codec or format.
- Timestamps.
- Final status.
- Error details.
- Whether original deletion was requested.
- Whether Photos confirmed the deletion transaction.

History shall distinguish successful compression from completed storage reclamation.

---

## 5. User Experience Specification

### 5.1 Application Structure

The application uses a three-region layout.

**Left sidebar**

- Apple Photos.
- All Media.
- Videos.
- Photos.
- Kept.
- Compression History.
- Settings.

**Main content**

- Page title and statistics.
- Description of available actions.
- Media type filters.
- Sort and date controls.
- Thumbnail grid.
- Selection indicators.
- File metadata.

**Bottom action bar**

- Number of selected assets.
- Combined verified size when available.
- Compression preset.
- Primary compression action.
- Processing queue indicator.

### 5.2 First Launch

1. Display a welcome screen.
2. Explain local compression and Photos permissions.
3. Ask the user to connect Apple Photos.
4. Request PhotoKit authorization.
5. Load thumbnails and accessible media metadata.
6. Begin a non-blocking metadata scan.
7. Display the library browser.

The user can browse while size analysis continues.

### 5.3 Main Library Screen

Every media card shall display:

- Thumbnail.
- Video indicator where applicable.
- Duration for videos.
- File size or size status.
- Creation date.
- Selection state.
- Primary actions.

Selected items are visually highlighted.

Toolbar filters include:

- All.
- Videos.
- Photos.
- Kept.
- Date range.
- Sort order.

### 5.4 Compression Interaction

The default interaction is:

1. Select one or more media assets.
2. Choose a compression preset.
3. Select "Compress Selected."
4. Watch download and compression progress.
5. Review the compression results.
6. Import valid replacements into Photos.
7. Optionally approve deletion of originals.

The "Compress Selected" action shall never imply automatic deletion unless the UI has clearly disclosed and obtained authorization for that action.

### 5.5 Error States

The application must display actionable messages for:

- Photos permission denied.
- Original unavailable.
- iCloud download failure.
- Insufficient disk space.
- Unsupported asset type.
- Unsupported video codec.
- Encoder failure.
- Cancellation.
- Imported asset verification failure.
- Deletion request failure.
- Library changed during processing.

---

## 6. System Architecture

### 6.1 Architecture Style

The application shall use SwiftUI with feature-oriented MVVM and explicit service boundaries.

The design separates:

- Presentation.
- Application orchestration.
- Domain logic.
- Photos access.
- Media processing.
- Persistence.

View models shall not directly contain compression algorithms or PhotoKit change-request logic.

### 6.2 High-Level Architecture

```text
SwiftUI Presentation
        |
        v
View Models
        |
        v
Application Coordinators
        |
        +----------------------+
        |                      |
        v                      v
Photos Library Service    Compression Queue
        |                      |
        v                      +--> Resource Exporter
PhotoKit                    |
        |                   +--> Image Compressor
        |                   |
        |                   +--> Video Compressor
        |                   |
        |                   +--> Output Validator
        |                   |
        |                   +--> Photos Importer
        |                   |
        |                   +--> Deletion Coordinator
        |
        v
Media Metadata Cache
        |
        v
SwiftData Persistence
```

### 6.3 Core Modules

**PhotosLibraryService**

Responsibilities:

- Authorization.
- Asset fetching.
- Library change observation.
- Resource discovery.
- Album mapping.
- Asset lookup by identifier.

**MediaScannerService**

Responsibilities:

- Asset enumeration.
- Metadata normalization.
- Size verification scheduling.
- Cache refresh.
- Library scan progress.

**ThumbnailService**

Responsibilities:

- Thumbnail retrieval.
- Preheating and caching.
- Request cancellation.
- Memory management.

**CompressionCoordinator**

Responsibilities:

- Operation lifecycle.
- Task scheduling.
- Cancellation.
- Recovery.
- Progress reporting.

**ImageCompressionService**

Responsibilities:

- Image format inspection.
- Image decoding and encoding.
- Resizing.
- Colorspace and orientation handling.

**VideoCompressionService**

Responsibilities:

- Video track inspection.
- Codec selection.
- Export configuration.
- Encoding.
- Output reporting.

**CompressionValidator**

Responsibilities:

- Structural media validation.
- Size comparisons.
- Duration checks.
- Track verification.
- Resolution and orientation checks.
- Metadata reporting.

**PhotosMutationService**

Responsibilities:

- Asset import.
- Import verification.
- Supported metadata restoration.
- Deletion requests.
- Safe error handling.

**CompressionHistoryStore**

Responsibilities:

- Operation records.
- Review status.
- Size cache records.
- Recovery checkpoints.
- Savings reporting.

---

## 7. Data Models

### 7.1 MediaAsset

```swift
struct MediaAsset: Identifiable, Sendable {
    let id: String
    let kind: MediaKind

    let creationDate: Date?
    let modificationDate: Date?

    let pixelWidth: Int
    let pixelHeight: Int
    let duration: TimeInterval?

    let size: MediaSizeState
    let capabilities: MediaCapabilities
    let reviewStatus: ReviewStatus
}
```

The identifier maps to PhotoKit's asset identifier.

Do not persist `PHAsset` objects directly in the application's domain or persistence layer.

### 7.2 MediaKind

```swift
enum MediaKind: String, Codable, Sendable {
    case photo
    case video
}
```

### 7.3 MediaSizeState

```swift
enum MediaSizeState: Sendable {
    case unknown
    case estimated(Int64)
    case verified(Int64)
    case unavailable(String)
}
```

A reported size is the byte count of the selected source payload actually exported for compression. For an eligible standard photo or video, this is its selected original image or video resource. Photos thumbnails, cached derivatives, unrelated auxiliary resources, and library overhead are excluded. Paired, edited, or otherwise ambiguous multi-resource assets are ineligible in the MVP rather than having an arbitrary resource selected.

An exact size requires a complete export and byte count. If the app cannot obtain that count, it must show an estimate or unavailable state and must not present exact savings.

### 7.4 CompressionPreset

```swift
enum CompressionPreset: String, Codable, Sendable {
    case highQuality
    case balanced
    case maximumSavings
}
```

### 7.5 CompressionJob

```swift
struct CompressionJob: Identifiable, Sendable {
    let id: UUID
    let assetID: String
    let preset: CompressionPreset

    var state: CompressionState
    var progress: Double
    var createdAt: Date
}
```

### 7.6 CompressionState

```swift
enum CompressionState: Sendable {
    case pending
    case downloading
    case compressing
    case validating
    case importing
    case verifyingImport
    case awaitingDeletionDecision
    case deletingOriginal
    case completed
    case skipped
    case failed
    case cancelled
}
```

Implementation must also persist durable, serializable phase identifiers and error records for recovery after restart.

### 7.7 CompressionResult

```swift
struct CompressionResult: Sendable {
    let originalBytes: Int64
    let compressedBytes: Int64

    let outputURL: URL
    let outputFormat: String

    let validationPassed: Bool
    let metadataWarnings: [String]

    var savedBytes: Int64 {
        max(0, originalBytes - compressedBytes)
    }
}
```

This model describes potential size reduction, not necessarily storage already reclaimed from Photos.

---

## 8. Compression Engine Design

### 8.1 Image Pipeline

```text
PHAsset
   |
   v
Select supported resource
   |
   v
Export original image
   |
   v
Inspect image properties
   |
   v
Choose output representation
   |
   v
Encode with ImageIO
   |
   v
Validate output
   |
   v
Compare file sizes
   |
   v
Return compressed result
```

Image processing should avoid unnecessary full-resolution bitmap allocations.

When resizing is required, prefer downsampling mechanisms appropriate for large images.

For output validation, confirm:

- File can be opened by ImageIO.
- Pixel dimensions match policy.
- Orientation is correct.
- Color information is preserved or changes are disclosed.
- Output format meets compatibility requirements.
- File size qualifies for meaningful savings.

### 8.2 Video Pipeline

```text
PHAsset
   |
   v
Export original video
   |
   v
Inspect AVAsset tracks
   |
   v
Choose supported export preset
   |
   v
Encode with AVFoundation
   |
   v
Validate audio/video tracks
   |
   v
Compare size and duration
   |
   v
Return compressed result
```

The initial implementation will prefer AVAssetExportSession for supported conversions.

AVAssetReader and AVAssetWriter may be introduced later for more precise bitrate, codec, and track management.

Do not assume a given export preset guarantees a smaller output.

### 8.3 Compression Decision Rules

A compression attempt shall be marked as skipped when:

- The source is unsupported.
- The output fails validation.
- Compression increases the file size.
- The measured size reduction falls below a configurable minimum.
- Required metadata cannot be preserved under the selected policy.
- The source has changed since processing began.

Initial minimum reduction is 5%. Compute it as `(sourceBytes - outputBytes) / sourceBytes` using verified byte counts for the selected source payload and output file. If either count is not verified, do not apply the threshold or report exact savings; mark the result as size-unverified and do not offer original deletion. The threshold is an internal preset value in the MVP, not a user-facing setting.

### 8.4 Temporary Files

Temporary files shall be stored in an app-managed working directory.

Each compression operation shall have its own workspace.

```text
Application Support/
  SlimKit/
    Jobs/
      <operation-id>/
        source/
        output/
        manifest.json
```

Requirements:

- Isolate jobs.
- Protect against filename collisions.
- Check available disk capacity.
- Avoid loading multi-gigabyte resources into memory.
- Clean up after successful completion.
- Retain necessary recovery artifacts after interrupted writes.
- Exclude temporary outputs from user-facing savings totals.

The app must account for the possibility of temporarily storing both original and compressed media.

---

## 9. Apple Photos Integration

### 9.1 Authorization

Use PhotoKit authorization APIs with read/write intent.

The application needs an `NSPhotoLibraryUsageDescription` explaining why it accesses the library.

PhotoKit permission callbacks shall be integrated into Swift concurrency without blocking the main thread.

Platform-specific authorization behavior shall be validated against the deployment target.

### 9.2 Resource Retrieval

Use PHAssetResourceManager for underlying resource access.

When an asset requires iCloud retrieval, allow network access for user-initiated compression jobs and report download progress.

Do not download full originals automatically during general thumbnail browsing.

### 9.3 Asset Creation

Create compressed assets using public PhotoKit change requests.

Keep the output file available until Photos completes the import and verification workflow.

Record the new PhotoKit identifier.

A successful change-request callback alone is not sufficient to claim that every replacement requirement has been met. Import verification requires re-fetching the replacement by its PhotoKit identifier, confirming its media type and expected dimensions (and video duration within one frame), and retrieving the imported resource to confirm it is readable and its byte count matches the validated output. If retrieval is unavailable, verification remains pending and deletion is prohibited. Verify creation date and location when those values were selected for preservation; record mismatches as failures, not silent success.

### 9.4 Asset Deletion

Deletion must be an independent step.

Requirements:

- Re-fetch the original asset.
- Re-verify the replacement asset.
- Check for duplicate or already-completed operations.
- Display a summary of affected assets.
- Obtain explicit confirmation.
- Submit a PhotoKit deletion request.
- Record the outcome.
- Refresh the browser and history.

Deletion failures must not remove or invalidate successfully imported replacements.

### 9.5 Asset Relationships

Photos can contain albums, edits, paired resources, and special media types.

The MVP shall use a capability-based eligibility model:

- Supported standard photo: one still-image original resource, no Photos adjustment resources, no paired RAW+JPEG, no Live Photo, no animation, no depth/portrait auxiliary data, and no HDR or wide-gamut feature that the selected output path cannot preserve and validate.
- Supported standard video: one video resource with supported SDR video and audio tracks, no Photos adjustment resources, no spatial/cinematic features, and no unsupported timed metadata, subtitle, or additional tracks.
- Unsupported complex photo or video: any asset with edits, paired or ambiguous resources, unsupported color/HDR/auxiliary features, or unrecognized media subtypes.
- Cloud resource currently unavailable.
- Unknown, pending inspection.

Eligibility must be determined before downloading the full source where possible, then rechecked against the exported resource before encoding and immediately before deletion. Uncertain classification means skip. The app shall not automatically treat a Live Photo's still image and video component as independent replacement assets.

---

## 10. iCloud Photos Behavior

### 10.1 Supported Scenarios

The application shall support assets that:

- Are fully stored locally.
- Have downloadable originals in iCloud.
- Are temporarily unavailable due to network errors.
- Are awaiting synchronization.

### 10.2 Download Policy

Downloading originals must be initiated only when necessary for a selected operation.

A batch download shall have:

- Progress.
- Cancellation.
- Error reporting.
- Limited concurrency.
- Disk capacity checks.

### 10.3 Storage Semantics

Three distinct measurements must be maintained.

**Compression reduction**

Original resource bytes minus compressed resource bytes.

**Potential Photos library reduction**

Expected source-to-replacement reduction if the original is eventually removed.

**Confirmed storage reclaimed**

Space actually demonstrated to be released, when reliably measurable.

The app shall not claim confirmed storage reclamation merely because a PhotoKit deletion request succeeded.

### 10.4 iCloud Synchronization

The application must explain:

- Imported media may need to upload to iCloud.
- Deletions may synchronize to other devices.
- Recently Deleted may retain storage.
- Local disk usage depends on Photos storage optimization.
- iCloud storage accounting may update asynchronously.

The app will not attempt to bypass Apple's iCloud Photos retention or synchronization behavior.

---

## 11. Persistence and Recovery

SwiftData will store:

- Asset review status.
- Verified size cache.
- Compression operations.
- Compression results.
- Replacement asset mappings.
- Workflow checkpoints.
- User preferences.

The application shall persist state at important transitions.

Example:

```text
Job Created
   -> Source Exported
   -> Compression Completed
   -> Output Validated
   -> Replacement Imported
   -> Import Verified
   -> User Decision Recorded
   -> Original Deletion Requested
   -> Job Finalized
```

After an unexpected restart, the recovery coordinator shall reconcile incomplete jobs with the current Photos library.

If the application cannot determine whether a replacement was imported, it must not blindly create another copy or delete the original.

Operations requiring uncertain recovery shall be marked "Needs Review."

---

## 12. Performance Requirements

### 12.1 Responsiveness

- The main window shall remain responsive during scanning.
- Thumbnail loading shall be lazy.
- Scrolling shall not trigger original media decoding.
- Background tasks shall respect cancellation.
- Progress shall update without excessive UI refreshes.

### 12.2 Large Libraries

Target test libraries:

- 1,000 assets.
- 10,000 assets.
- 50,000 assets.
- 100,000 assets.

The app shall avoid keeping complete thumbnail collections in RAM.

### 12.3 Compression

Initial resource limits:

- One video encoding job at a time.
- A bounded number of image jobs.
- A bounded number of iCloud downloads.
- Adjustable concurrency based on performance testing.

Memory and disk pressure shall cause work to pause, reduce concurrency, or fail safely.

### 12.4 Performance Targets

Provisional, subject to measurement:

- Launch to interactive shell: under 2 seconds on reference hardware.
- Initial visible thumbnail population: under 3 seconds for locally available assets.
- Smooth grid scrolling under normal conditions.
- No unbounded increase in memory during long scans.
- No unbounded accumulation of temporary files.

These are engineering targets, not guaranteed timings across all Mac models and iCloud configurations.

---

## 13. Security and Privacy

### 13.1 Privacy Requirements

- All compression happens locally.
- No user photos or videos are uploaded to the application's servers.
- No third-party analytics receives asset filenames or content.
- Photos permissions are requested only when needed.
- Temporary resources are removed when no longer necessary.
- Sensitive file paths and metadata are excluded from diagnostic logs by default.

### 13.2 macOS Sandbox

The application shall use App Sandbox where required for the intended distribution method.

Photos access must be configured through the appropriate permission and entitlement mechanisms.

Temporary files shall remain within permitted application locations.

### 13.3 Data Integrity

- Never edit files inside the Photos library package directly.
- Never delete assets based solely on matching filenames.
- Use PhotoKit identifiers for asset references.
- Verify the selected original before deletion.
- Treat imported replacements as independent assets.
- Guard against duplicate operations.
- Record errors without falsely marking tasks complete.

---

## 14. Error Handling

All operations shall return typed errors.

Suggested error categories:

```text
AuthorizationError
AssetUnavailableError
ResourceDownloadError
UnsupportedFormatError
InsufficientDiskSpaceError
ImageEncodingError
VideoEncodingError
ValidationError
PhotosImportError
PhotosDeletionError
OperationCancelledError
RecoveryRequiredError
```

User-facing errors must explain both the failure and its consequences.

Examples:

**Download failed:** "The original video could not be downloaded from iCloud. No changes were made to your Photos library."

**Import failed:** "Compression completed, but the smaller copy could not be saved to Photos. Your original is unchanged."

**Deletion failed:** "The compressed copy is saved in Photos, but the original was not deleted. Both versions are still available."

---

## 15. Testing Strategy

### 15.1 Unit Tests

Cover:

- Media type classification.
- Compression eligibility.
- File size calculations.
- Savings calculations.
- Preset configuration.
- Queue state transitions.
- Job cancellation.
- Recovery decisions.
- Metadata comparison.
- Error mapping.

### 15.2 Integration Tests

Use dedicated test Photos libraries for:

- Permission handling.
- Asset fetching.
- Media resource export.
- Compressed asset import.
- Identifier retrieval.
- Deletion.
- Library change observation.
- iCloud-only media.

Never execute destructive integration tests against a developer's personal Photos library.

### 15.3 Media Compatibility Matrix

| Media | Expected MVP behavior |
|---|---|
| Standard JPEG | Compress |
| Standard HEIC | Compress if compatible |
| PNG | Compress or convert where safe |
| TIFF | Convert only when supported |
| H.264 video | Compress |
| HEVC video | Compress when beneficial |
| 4K SDR video | Compress |
| RAW photo | Browse, compression deferred |
| Live Photo | Browse, compression deferred |
| ProRes video | Browse; support requires separate validation |
| HDR video | Browse; advanced compression deferred |
| Animated image | Browse; compression deferred |

### 15.4 Safety Tests

Critical scenarios:

1. App crashes during each workflow phase; recovery reconciles Photos state and never deletes the source when import or verification is uncertain.
2. App crashes after import but before the replacement identifier or checkpoint is persisted; recovery finds the replacement or marks the job Needs Review without importing a duplicate or deleting the source.
3. The source is edited, deleted, or otherwise changed after scanning or during compression; the job is invalidated and original deletion is prohibited.
4. Replacement import succeeds but resource retrieval, media checks, or metadata verification fails; the original remains untouched.
5. User cancels during download, encoding, import, verification, and the deletion confirmation; no unapproved deletion occurs and temporary files are reconciled.
6. The user denies, revokes, or reduces Photos access during a job; inaccessible assets are not modified and the job records an actionable failure.
7. Disk space runs out while downloading, encoding, or importing; partial outputs are not treated as valid replacements and the original remains.
8. Deletion request fails or its outcome is uncertain; the replacement remains, the source is not reported as reclaimed, and recovery requires reconciliation.
9. A paired, edited, Live Photo, HDR, animated, or otherwise ambiguous asset is presented for compression; it is skipped unless the declared eligibility checks pass.
10. Source size is estimated or unavailable; the app does not report exact savings, apply the 5% rule as an exact result, or enable deletion.