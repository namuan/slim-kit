XCODEGEN ?= xcodegen
XCODEBUILD ?= xcodebuild
SCHEME ?= SlimKit
CONFIGURATION ?= Debug
DERIVED_DATA ?= .build
APP_PATH = $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/SlimKit.app

.PHONY: generate build test run clean

generate:
	$(XCODEGEN) generate

build: generate
	$(XCODEBUILD) -quiet -project SlimKit.xcodeproj -scheme $(SCHEME) -configuration $(CONFIGURATION) -destination 'platform=macOS' -derivedDataPath $(DERIVED_DATA) build

test: generate
	$(XCODEBUILD) -quiet -project SlimKit.xcodeproj -scheme $(SCHEME) -configuration $(CONFIGURATION) -destination 'platform=macOS' -derivedDataPath $(DERIVED_DATA) test

run: build
	open -n "$(APP_PATH)"

clean:
	rm -rf "$(DERIVED_DATA)"
