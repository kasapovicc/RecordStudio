# RecordStudio (native). `make run` builds, signs and opens the app; `make test` runs every test;
# `make dmg` builds a universal app and packs it in a disk image to share.
APP     := build/RecordStudio.app
BIN     := .build/release/RecordStudio
# Sign with your Apple Development identity when there is one, so macOS remembers the Screen Recording
# permission across rebuilds; otherwise ad-hoc (you'll be asked again after each rebuild).
IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $$2; exit}')
ENV_ARGS := $(shell [ -f .env ] && grep -E '^[A-Z_]+=.+' .env | sed 's/^/--env /')
# Builds look for updates in this repository's origin, and PUBLIC=1 builds in the public repository (see README ›
# Publishing a release).
PUBLIC_REPO  := kasapovicc/RecordStudio
UPDATE_REPO  ?= $(if $(PUBLIC),$(PUBLIC_REPO),$(shell git remote get-url origin 2>/dev/null | sed -E 's,.*github.com[:/],,; s,\.git$$,,'))

.PHONY: run app app-bundle dmg release test clean

# A copy left running in the menu bar would just be brought forward by `open`, so quit it first.
run: app
	-@pkill -x RecordStudio && while pgrep -x RecordStudio >/dev/null; do sleep 0.1; done
	open $(ENV_ARGS) "$(APP)"

app:
	swift build -c release
	$(MAKE) app-bundle

app-bundle:
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$(BIN)" "$(APP)/Contents/MacOS/RecordStudio"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	cp Resources/Sample.recordstudio "$(APP)/Contents/Resources/Sample.recordstudio"
	$(if $(BUNDLE_ID),/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(BUNDLE_ID)" "$(APP)/Contents/Info.plist")
	/usr/libexec/PlistBuddy -c "Add :RecordStudioVersion string $(VERSION)$(if $(LABEL),-$(LABEL))" "$(APP)/Contents/Info.plist"
	$(if $(UPDATE_REPO),/usr/libexec/PlistBuddy -c "Add :RecordStudioUpdateRepository string $(UPDATE_REPO)" "$(APP)/Contents/Info.plist")
	# The layered Icon Composer icon compiles to Assets.car (glass, dark, clear and tinted) plus an AppIcon.icns fallback.
	xcrun actool Resources/AppIcon.icon --compile "$(APP)/Contents/Resources" --platform macosx --minimum-deployment-target 26.0 \
		--app-icon AppIcon --output-partial-info-plist "$(APP)/../AppIcon-info.plist" >/dev/null
	codesign --force $(SIGN_FLAGS) --sign "$(if $(IDENTITY),$(IDENTITY),-)" "$(APP)"
	@echo "Built $(APP) (signed: $(if $(IDENTITY),$(IDENTITY),ad-hoc))"

# The disk image is named after the version in Info.plist plus an optional label, e.g. `make dmg LABEL=beta.1`.
VERSION := $(shell sed -n 's:.*<key>CFBundleShortVersionString</key><string>\(.*\)</string>.*:\1:p' Resources/Info.plist)
DMG     := build/RecordStudio-$(VERSION)$(if $(LABEL),-$(LABEL)).dmg
# With a Developer ID certificate the image is signed, notarized and stapled, so it opens without a warning.
# Notarizing reads credentials saved once with `xcrun notarytool store-credentials RecordStudio …` (see README).
DEVELOPER_ID   ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $$2; exit}')
NOTARY_PROFILE ?= RecordStudio
# Shared builds get their own bundle id, so macOS keeps their permissions apart from `make run` builds.
RELEASE_ID     ?= com.kasapovic.RecordStudio

dmg:
	swift build -c release --arch arm64 --arch x86_64
	$(MAKE) app-bundle BIN=.build/apple/Products/Release/RecordStudio BUNDLE_ID=$(RELEASE_ID) \
		$(if $(DEVELOPER_ID),IDENTITY="$(DEVELOPER_ID)" SIGN_FLAGS="--options runtime --timestamp --entitlements Resources/RecordStudio.entitlements")
	rm -rf build/dmg build/rw.dmg "$(DMG)"
	mkdir -p build/dmg
	cp -R "$(APP)" build/dmg/
	ln -s /Applications build/dmg/Applications
	Resources/DiskImage/dmg-window --render build/dmg
	# A read-write image first, so Finder can lay out its window (Resources/DiskImage/dmg-window), then the compressed one.
	hdiutil create -volname "RecordStudio" -srcfolder build/dmg -ov -format UDRW build/rw.dmg
	MOUNT=$$(hdiutil attach -readwrite -noverify -noautoopen build/rw.dmg | awk -F'\t' '/\/Volumes\// {print $$NF}') && \
		Resources/DiskImage/dmg-window --layout "$$MOUNT" && sync && \
		{ hdiutil detach "$$MOUNT" || { sleep 2; hdiutil detach -force "$$MOUNT"; }; }
	hdiutil convert build/rw.dmg -format UDZO -o "$(DMG)"
	rm -rf build/dmg build/rw.dmg
ifneq ($(DEVELOPER_ID),)
	codesign --force --timestamp --sign "$(DEVELOPER_ID)" "$(DMG)"
	xcrun notarytool submit "$(DMG)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(DMG)"
	spctl --assess --type open --context context:primary-signature -v "$(DMG)"
	@echo "Built $(DMG) (notarized)"
else
	@echo "Built $(DMG) (not notarized: no Developer ID Application certificate in the keychain)"
endif

# Publishes the disk image as a GitHub release, which is what the app's updater reads. A LABEL makes it a beta.
# Release notes come from NOTES (a Markdown file) when given, else GitHub writes them from the merged pull requests.
TAG := v$(VERSION)$(if $(LABEL),-$(LABEL))
release: dmg
	gh release create "$(TAG)" "$(DMG)" --title "RecordStudio $(VERSION)$(if $(LABEL), $(subst ., ,$(LABEL)))" \
		$(if $(LABEL),--prerelease) $(if $(NOTES),--notes-file "$(NOTES)",--generate-notes)

test:
	swift test

clean:
	rm -rf .build build
