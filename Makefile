# Credential-free test executor for the Touchpoint iOS SDK. Nothing here needs a device, a network
# connection beyond SwiftPM's dependency fetch, or any credential.
#
#   make check        everything below, in order — the pre-push bar. The app-build gate needs FULL
#                     XCODE (it skips itself where xcodebuild cannot run). On a CommandLineTools-only
#                     machine use `make check-clt`.
#   make check-clt    check minus the competing-pin and app-build gates; the CLT-only subset
#   make precommit    the fast subset wired into .git/hooks/pre-commit (lint + staged secret scan)
#   make test         macOS unit tier. Note the limit: Chime and the Connect chat SDK are linked on
#                     iOS only, so on macOS the Chat and Voice targets compile against Core alone.
#                     `make build-ios` is the only step that proves the real SDK link.
#   make build-ios    all four products for a generic iOS device, with the real Chime/chat SDKs
#   make hooks        install the pre-commit (precommit) and pre-push (check) hooks
#
# From a shell inside another sandbox (some agent runtimes), SwiftPM's own sandbox cannot nest;
# set SWIFTPM_FLAGS=--disable-sandbox. Never make that the default.

SWIFT        ?= swift
SWIFTPM_FLAGS ?=
XCODEBUILD   ?= xcodebuild
SCHEME       ?= Touchpoint-Package

.PHONY: check check-clt precommit build test build-ios lint scan graph privacy strings symbols scripts hooks clean pins demo demo-project declarations

# The app-build gate runs only where an example app exists: the public tree has none yet.
DEMO_GATE := $(if $(wildcard Scripts/check-demo-builds.sh),demo,)

check: build test lint scan graph privacy declarations strings symbols scripts pins $(DEMO_GATE)
	@mkdir -p .build && git rev-parse HEAD > .build/check-stamp && git diff --quiet HEAD -- . || echo dirty >> .build/check-stamp
	@echo "✔ make check: all credential-free gates passed (stamped for pre-push)"

check-clt: build test lint scan graph privacy declarations strings symbols scripts
	@echo "✔ make check-clt: all gates except competing pins and the app build passed"

precommit: lint scan-staged
	@echo "✔ precommit gates passed"

build:
	$(SWIFT) build $(SWIFTPM_FLAGS)

test:
	$(SWIFT) test $(SWIFTPM_FLAGS)

# Links the iOS-only dependencies (Chime, the Connect chat SDK and the AWS SDK for Swift). Needs full
# Xcode and takes longer than the rest of `check` combined, so it is a separate target; run it before
# any dependency bump and in CI. `-skipPackagePluginValidation`: the AWS SDK for Swift builds its
# clients with smithy-swift's code-generator plugin, which xcodebuild otherwise refuses to run
# untrusted (the chat SDK's migration guide gives the same flag for CLI builds).
build-ios:
	$(XCODEBUILD) -scheme $(SCHEME) -destination 'generic/platform=iOS' -derivedDataPath .build/DerivedData -skipPackagePluginValidation build

lint:
	sh Scripts/lint.sh

scan:
	sh Scripts/scan-secrets.sh

scan-staged:
	sh Scripts/scan-secrets.sh --staged

graph:
	sh Scripts/check-build-graph.sh

privacy:
	sh Scripts/check-privacy-manifests.sh

declarations:
	sh Scripts/check-inherited-declarations.sh

strings:
	sh Scripts/check-string-catalog.sh

symbols:
	sh Scripts/check-release-symbols.sh

scripts:
	sh Scripts/test-scripts.sh

pins:
	sh Scripts/check-competing-pins.sh


hooks:
	sh Scripts/install-hooks.sh

clean:
	rm -rf .build
