APP     := Kweku
SDK      = $(shell xcrun --show-sdk-path)
DEPLOY  := 13.0
KIT     := $(shell find Sources/KwekuKit -name '*.swift')
HOST    := Sources/Kweku/main.swift
ARCHES  := arm64 x86_64

APPDIR  := build/$(APP).app
MACOS   := $(APPDIR)/Contents/MacOS
EXEC    := $(MACOS)/$(APP)
DYLIB   := KwekuKit.dylib
LIBDIR   = $(HOME)/Library/Application Support/$(APP)/lib

# ── Why the app is split in two ───────────────────────────────────────────────
#
# Ad-hoc signing ("-") makes macOS derive the designated requirement from the
# bundle's cdhash, which seals the executable, Info.plist, the entitlements and
# CodeResources. TCC files Screen Recording / Microphone / Accessibility grants
# against that requirement, so touching anything inside the bundle reads as a
# brand-new app and drops every permission.
#
# So the bundle is *frozen*: `make host` builds it once, and the only thing in
# it is an inert loader. All real code compiles into KwekuKit.dylib, installed
# to ~/Library/Application Support/Kweku/lib/ — outside the bundle, outside the
# seal. `make app` rebuilds only that, so the cdhash never moves and the grants
# survive every rebuild. See the header comment in Sources/Kweku/main.swift.
#
# Universal builds via `swift build --arch` need Xcode's xcbuild, absent with
# Command Line Tools only, so each slice is compiled with swiftc and lipo'd.
# For a faster inner loop on Apple Silicon: `make app ARCHES=arm64`.
.PHONY: all build test app host install-dylib run restart size cdhash clean dist notarize

all: app

## Compile the churning library — the thing you rebuild all day.
build:
	@mkdir -p build/universal
	@for arch in $(ARCHES); do \
	  echo "==> compiling $$arch"; \
	  odir=build/obj/$$arch; mkdir -p $$odir; \
	  swiftc -sdk "$(SDK)" -target $$arch-apple-macos$(DEPLOY) -Osize -wmo \
	    -parse-as-library -module-name KwekuKit \
	    -emit-library -o $$odir/$(DYLIB) $(KIT) || exit 1; \
	done
	@lipo -create -output build/universal/$(DYLIB) \
	  $(foreach a,$(ARCHES),build/obj/$(a)/$(DYLIB))
	@strip -x build/universal/$(DYLIB) || true
	@# lipo discards the ad-hoc signature the linker applies, and arm64 refuses
	@# to dlopen unsigned code — so re-sign. This is outside the app bundle and
	@# does not affect its cdhash.
	@codesign --force --sign - build/universal/$(DYLIB)
	@echo "==> universal library: build/universal/$(DYLIB)"

## Install the library where the frozen host looks for it. Replaced by rename
## so a running Kweku keeps the copy it already mapped instead of crashing.
install-dylib: build
	@mkdir -p "$(LIBDIR)"
	@chmod 700 "$(LIBDIR)"
	@cp build/universal/$(DYLIB) "$(LIBDIR)/.$(DYLIB).new"
	@mv -f "$(LIBDIR)/.$(DYLIB).new" "$(LIBDIR)/$(DYLIB)"
	@echo "==> installed $(LIBDIR)/$(DYLIB)"

## Run the pure-logic tests (geometry + hit-state) via SwiftPM.
test:
	swift run KwekuTests

## Everyday build: library only. The bundle — and every permission granted to
## it — is left exactly as it was.
app: install-dylib
	@if [ ! -d "$(APPDIR)" ]; then \
	  echo "==> no frozen bundle yet, building one"; \
	  $(MAKE) --no-print-directory host; \
	else \
	  echo "==> bundle untouched, cdhash unchanged, permissions preserved"; \
	fi

## Build and FREEZE the app bundle. Run this once. Every later run re-hashes
## the bundle and costs one round of re-granting Screen Recording / Mic /
## Accessibility — so only when main.swift, Info.plist or the entitlements
## actually change.
host:
	@mkdir -p build/universal
	@for arch in $(ARCHES); do \
	  echo "==> compiling host $$arch"; \
	  odir=build/obj/$$arch; mkdir -p $$odir; \
	  swiftc -sdk "$(SDK)" -target $$arch-apple-macos$(DEPLOY) -Osize \
	    -module-name $(APP) $(HOST) -o $$odir/$(APP) || exit 1; \
	done
	@lipo -create -output build/universal/$(APP) \
	  $(foreach a,$(ARCHES),build/obj/$(a)/$(APP))
	rm -rf "$(APPDIR)"
	mkdir -p "$(MACOS)" "$(APPDIR)/Contents/Resources"
	cp Resources/Info.plist "$(APPDIR)/Contents/Info.plist"
	cp build/universal/$(APP) "$(EXEC)"
	strip -STx "$(EXEC)" || true
	codesign --force --sign - --entitlements Resources/$(APP).entitlements "$(APPDIR)"
	@echo
	@echo "!! Bundle re-frozen at a new identity — macOS sees a new app, so"
	@echo "!! Screen Recording / Microphone / Accessibility need granting once more."
	@$(MAKE) --no-print-directory cdhash

## Print the frozen identity. Rerun after `make app` — it must not change.
cdhash:
	@codesign -d --verbose=4 "$(APPDIR)" 2>&1 | grep -E '^CDHash|^Signature' || true
	@codesign -d -r- "$(APPDIR)" 2>&1 | grep 'designated' || true

## Rebuild, then restart the running app so the new library is actually loaded.
run: app restart

restart:
	@pkill -x $(APP) 2>/dev/null || true
	@sleep 0.5
	@open "$(APPDIR)"
	@echo "==> $(APP) restarted"

## Report stripped sizes and arch slices (2 MB budget).
size: app
	@echo "== $(APP) sizes =="
	@ls -l "$(EXEC)" build/universal/$(DYLIB) \
	  | awk '{printf "%-12s %s bytes (%.3f MB)\n", $$9, $$5, $$5/1048576}'
	@lipo -info "$(EXEC)" build/universal/$(DYLIB)

clean:
	swift package clean 2>/dev/null || true
	rm -rf build

## Distribution bundle: library sealed *inside*, which is correct once a real
## certificate makes the requirement cert-based rather than a hash. Needs a
## Developer ID identity, which this environment doesn't have.
dist: build host
	cp build/universal/$(DYLIB) "$(APPDIR)/Contents/Resources/$(DYLIB)"
	codesign --force --deep --sign - --entitlements Resources/$(APP).entitlements "$(APPDIR)"

## Developer ID sign + notarize + staple (requires credentials).
notarize: dist
	./notarize.sh "$(APPDIR)"
