# SPEC §4.
SWIFT_BIN := $(shell dirname "$$(xcrun --find swift)")
# The swift-testing macro plugin is passed explicitly: with the Command Line Tools' Swift 6.4, SwiftPM's
# default build system intermittently omits it ("plugin for module 'TestingMacros' not found";
# 3 of 6 clean runs on 2026-10-04, 0 of 6 with this flag).
TESTING_PLUGINS := $(SWIFT_BIN)/../lib/swift/host/plugins/testing

.PHONY: build test bundle install uninstall

build:
	swift build

test:
	swift test -Xswiftc -plugin-path -Xswiftc "$(TESTING_PLUGINS)"

bundle:
	scripts/bundle.sh

install:
	scripts/install.sh

uninstall:
	scripts/uninstall.sh
