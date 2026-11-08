# SlimKit

SlimKit is a native macOS utility for reviewing a Photos library and locally compressing supported photos and videos.

## Run

Requires macOS 14+, Apple’s command-line build tools, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
make run
```

Run tests with `make test`.

## Current scope

SlimKit browses Photos, previews media, verifies selected-resource byte counts, and compresses eligible selections locally. Compression results show measured input/output sizes, savings, output format, dimensions, and preset. Import is a separate user action; a replacement is only considered verified after PhotoKit re-fetch, metadata checks, resource export, capability inspection, and exact byte-count comparison.

Original deletion is a separate explicit action. It is blocked unless the source and replacement are freshly re-verified, and the user confirms a second warning. An uncertain import or deletion outcome requires review; recovery never blindly repeats an import or deletion. SlimKit does not claim that removed items immediately reclaim storage.

All automated tests use local fixtures and injected Photos boundaries. Live PhotoKit import/deletion, distribution-specific sandbox validation, dedicated-library compatibility testing, and library-scale performance profiling remain unvalidated. Do not test against a personal Photos library. Live mutation testing requires a disposable Photos library and explicit human approval.

[License](LICENSE)
