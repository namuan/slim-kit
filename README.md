# SlimKit

SlimKit is a native macOS app for browsing Apple Photos and, eventually, safely compressing selected media locally. It is in early development; compression is not implemented yet.

## Run

Requires macOS 14+, Apple’s command-line build tools, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
make run
```

Run tests with `make test`.

## Current scope

SlimKit can browse Photos, preview media, and verify selected resource sizes. If an original is only in iCloud, SlimKit asks before requesting it over the network; previews do not modify the Photos library. Compression, import, and deletion are not implemented.

[License](LICENSE)
