APP     := Charlie
SDK      = $(shell xcrun --show-sdk-path)
DEPLOY  := 13.0
KIT     := $(shell find Sources/CharlieKit -name '*.swift')
MAIN    := Sources/Charlie/main.swift
ARCHES  := arm64 x86_64

APPDIR  := build/$(APP).app
MACOS   := $(APPDIR)/Contents/MacOS
EXEC    := $(MACOS)/$(APP)

# Universal builds via `swift build --arch` require Xcode's xcbuild, which is
# absent with Command Line Tools only. We instead compile each slice with
# swiftc (-Osize) and lipo them together — reliable under CLT, no deps.
.PHONY: all build test app run size clean notarize

all: app

## Compile the universal, size-optimised binary into build/universal/.
build:
	@mkdir -p build/universal
	@for arch in $(ARCHES); do \
	  echo "==> compiling $$arch"; \
	  odir=build/obj/$$arch; mkdir -p $$odir; \
	  swiftc -sdk "$(SDK)" -target $$arch-apple-macos$(DEPLOY) -Osize -wmo \
	    -parse-as-library -module-name CharlieKit \
	    -emit-module -emit-module-path $$odir/CharlieKit.swiftmodule \
	    -c -o $$odir/CharlieKit.o $(KIT) || exit 1; \
	  swiftc -sdk "$(SDK)" -target $$arch-apple-macos$(DEPLOY) -Osize \
	    -I $$odir -module-name Charlie \
	    $$odir/CharlieKit.o $(MAIN) -o $$odir/$(APP) || exit 1; \
	done
	@lipo -create -output build/universal/$(APP) \
	  $(foreach a,$(ARCHES),build/obj/$(a)/$(APP))
	@echo "==> universal binary: build/universal/$(APP)"

## Run the pure-logic tests (geometry + hit-state) via SwiftPM.
test:
	swift run CharlieTests

## Assemble a runnable .app bundle and ad-hoc sign it for local testing.
## Real distribution signing/notarization lives in notarize.sh (needs a
## Developer ID identity, which this environment lacks).
app: build
	rm -rf "$(APPDIR)"
	mkdir -p "$(MACOS)" "$(APPDIR)/Contents/Resources"
	cp Resources/Info.plist "$(APPDIR)/Contents/Info.plist"
	cp build/universal/$(APP) "$(EXEC)"
	strip -STx "$(EXEC)" || true
	codesign --force --deep --sign - --entitlements Resources/$(APP).entitlements "$(APPDIR)"
	@echo "Built $(APPDIR)"

## Launch the bundled app.
run: app
	open "$(APPDIR)"

## Report the stripped mach-o size and arch slices (2 MB budget).
size: app
	@echo "== $(APP) binary size =="
	@ls -l "$(EXEC)" | awk '{printf "%s bytes (%.3f MB)\n", $$5, $$5/1048576}'
	@lipo -info "$(EXEC)"

clean:
	swift package clean 2>/dev/null || true
	rm -rf build

## Developer ID sign + notarize + staple (requires credentials).
notarize: app
	./notarize.sh "$(APPDIR)"
