PROJECT := VoiceInk.xcodeproj
SCHEME := VoiceInk
XCODE_DEVELOPER_DIR := /Applications/Xcode-beta.app/Contents/Developer
XCODEBUILD := env DEVELOPER_DIR=$(XCODE_DEVELOPER_DIR) "$(XCODE_DEVELOPER_DIR)/usr/bin/xcodebuild"
XCODE_SWIFT := "$(XCODE_DEVELOPER_DIR)/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
MACOS_DESTINATION := platform=macOS,arch=arm64
LOCAL_DERIVED_DATA := $(CURDIR)/.local-build

# Stable local signing identity so TCC permission grants survive rebuilds.
# Created once via: openssl self-signed cert imported to the login keychain.
LOCAL_SIGN_IDENTITY := VoiceInk Local

.PHONY: all clean build build-debug build-release list destinations local check \
	healthcheck test test-swift test-unit test-ui test-ui-build runtime-proof proof dev \
	dev-restore run run-local install archive-stock help

# The default path is a deterministic, project-local Debug build.
all: check build-debug

# Prerequisites. Every build/test target below invokes this exact Xcode 27
# toolchain, without changing the user's global xcode-select setting.
check:
	@command -v git >/dev/null 2>&1 || { echo "git is not installed"; exit 1; }
	@test -x "$(XCODE_DEVELOPER_DIR)/usr/bin/xcodebuild" || { echo "Xcode 27 is not installed at $(XCODE_DEVELOPER_DIR)"; exit 1; }
	@version="$$($(XCODEBUILD) -version | sed -n '1p')"; \
	case "$$version" in \
		Xcode\ 27.*) ;; \
		*) echo "Expected an Xcode 27 toolchain at $(XCODE_DEVELOPER_DIR), found $$version"; exit 1 ;; \
	esac
	@test -x $(XCODE_SWIFT) || { echo "Swift toolchain is missing from Xcode 27"; exit 1; }
	@echo "Using $$($(XCODEBUILD) -version | sed -n '1p')"

healthcheck: check

list: check
	$(XCODEBUILD) -project $(PROJECT) -list

destinations: check
	$(XCODEBUILD) -project $(PROJECT) -showdestinations -scheme $(SCHEME)

# Unsigned build/test commands stay inside .local-build and never install an
# app. CODE_SIGNING_ALLOWED=NO keeps the compiler warning inventory focused on
# source/project warnings rather than local certificate state.
BUILD_FLAGS = -project $(PROJECT) -scheme $(SCHEME) -destination '$(MACOS_DESTINATION)' -derivedDataPath "$(LOCAL_DERIVED_DATA)" CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

build: build-debug

build-debug: check
	$(XCODEBUILD) $(BUILD_FLAGS) -configuration Debug build

build-release: check
	$(XCODEBUILD) $(BUILD_FLAGS) -configuration Release build

# Swift Testing (VoiceInkTests) is kept separate from UI/runtime proof so a
# source-only test run does not launch the application or touch TCC state.
test: test-swift

test-swift: test-unit

test-unit: check
	$(XCODEBUILD) $(BUILD_FLAGS) -configuration Debug -only-testing:VoiceInkTests test

# UI tests launch only the project-local test host. Refuse to start if any
# VoiceInk process is already running, which protects an installed copy with
# the same bundle identifier from being terminated or reused by XCTest.
test-ui: check
	@if pgrep -x VoiceInk >/dev/null 2>&1; then \
		echo "Refusing UI test: a VoiceInk process is already running. Quit it manually, then retry."; \
		exit 1; \
	fi
	$(XCODEBUILD) $(BUILD_FLAGS) -configuration Debug -parallel-testing-enabled NO -only-testing:VoiceInkUITests test

# Compile and discover the UI-test bundle without launching any app. This is
# the safe CI/local baseline when the installed app has the same bundle ID.
test-ui-build: check
	$(XCODEBUILD) $(BUILD_FLAGS) -configuration Debug -parallel-testing-enabled NO build-for-testing

# Narrow runtime proof for the menu-bar app launch/screenshot test. This is
# intentionally opt-in because it starts the app and may request TCC access.
runtime-proof: check
	@if pgrep -x VoiceInk >/dev/null 2>&1; then \
		echo "Refusing runtime proof: a VoiceInk process is already running. Quit it manually, then retry."; \
		exit 1; \
	fi
	$(XCODEBUILD) $(BUILD_FLAGS) -configuration Debug -parallel-testing-enabled NO -only-testing:VoiceInkUITests/VoiceInkUITestsLaunchTests/testLaunch test

proof: build-debug build-release test-swift

# Local signed Release build for manual runtime checks. The output remains in
# this repository's ignored DerivedData directory; it is never copied to
# ~/Downloads or /Applications.
local: check
	@echo "Building VoiceInk for local use in $(LOCAL_DERIVED_DATA)..."
	$(XCODEBUILD) -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-destination '$(MACOS_DESTINATION)' \
		-derivedDataPath "$(LOCAL_DERIVED_DATA)" \
		-xcconfig LocalBuild.xcconfig \
		CODE_SIGN_IDENTITY="$(LOCAL_SIGN_IDENTITY)" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=YES \
		DEVELOPMENT_TEAM="" \
		CODE_SIGN_ENTITLEMENTS="$(CURDIR)/VoiceInk/VoiceInk.local.entitlements" \
		SWIFT_ACTIVE_COMPILATION_CONDITIONS='$$(inherited) LOCAL_BUILD' \
		build
	@APP_PATH="$(LOCAL_DERIVED_DATA)/Build/Products/Release/VoiceInk.app"; \
	if [ -d "$$APP_PATH" ]; then \
		echo "Build complete: $$APP_PATH"; \
	else \
		echo "Error: expected local app at $$APP_PATH"; \
		exit 1; \
	fi

# Open only the exact project-local app produced by `make local`. Do not use
# open -n or kill-and-run behavior here: a running VoiceInk process may be the
# user's installed /Applications/VoiceInk.app copy.
run-local: check
	@APP_PATH="$(LOCAL_DERIVED_DATA)/Build/Products/Release/VoiceInk.app"; \
	if [ ! -d "$$APP_PATH" ]; then \
		echo "No project-local app found at $$APP_PATH; run 'make local' first."; \
		exit 1; \
	fi; \
	if pgrep -x VoiceInk >/dev/null 2>&1; then \
		echo "Refusing to launch: a VoiceInk process is already running. Quit it manually, then retry."; \
		exit 1; \
	fi; \
	echo "Opening $$APP_PATH"; \
	open "$$APP_PATH"

dev: local
	@set -eu; \
	APP_PATH="$(LOCAL_DERIVED_DATA)/Build/Products/Release/VoiceInk.app"; \
	if pgrep -x VoiceInk >/dev/null 2>&1; then \
		echo "Stopping the running VoiceInk for this explicit dev session"; \
		osascript -e 'tell application id "com.prakashjoshipax.VoiceInk" to quit'; \
	fi; \
	for attempt in 1 2 3 4 5 6 7 8 9 10; do \
		if ! pgrep -x VoiceInk >/dev/null 2>&1; then break; fi; \
		sleep 0.2; \
	done; \
	if pgrep -x VoiceInk >/dev/null 2>&1; then \
		echo "VoiceInk did not exit after the explicit stop request; refusing to launch the dev copy."; \
		exit 1; \
	fi; \
	echo "Opening $$APP_PATH"; \
	open "$$APP_PATH"

# End an intentional dev session and reopen the installed copy. This does not
# copy, delete, or replace either app bundle.
dev-restore: check
	@set -eu; \
	INSTALLED_APP="/Applications/VoiceInk.app"; \
	if pgrep -x VoiceInk >/dev/null 2>&1; then \
		echo "Stopping the development VoiceInk"; \
		osascript -e 'tell application id "com.prakashjoshipax.VoiceInk" to quit'; \
	fi; \
	for attempt in 1 2 3 4 5 6 7 8 9 10; do \
		if ! pgrep -x VoiceInk >/dev/null 2>&1; then break; fi; \
		sleep 0.2; \
	done; \
	if [ -d "$$INSTALLED_APP" ]; then \
		echo "Opening $$INSTALLED_APP"; \
		open "$$INSTALLED_APP"; \
	else \
		echo "No installed VoiceInk.app found; dev copy is stopped."; \
	fi

run: run-local

# Explicit install path retained for deliberate packaging work. Ordinary
# development targets above never call this target and never touch /Applications.
archive-stock:
	@if [ -d "/Applications/VoiceInk.app" ]; then \
		V=$$(defaults read /Applications/VoiceInk.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo unknown); \
		OUT="$$HOME/Downloads/VoiceInk-$$V-backup.zip"; \
		ditto -c -k --keepParent /Applications/VoiceInk.app "$$OUT"; \
		echo "Archived /Applications/VoiceInk.app -> $$OUT"; \
	else \
		echo "No /Applications/VoiceInk.app to archive"; \
	fi

install: local
	-@osascript -e 'tell application "VoiceInk" to quit' 2>/dev/null; sleep 2
	@rm -rf /Applications/VoiceInk.app
	@ditto "$(LOCAL_DERIVED_DATA)/Build/Products/Release/VoiceInk.app" /Applications/VoiceInk.app
	@xattr -cr /Applications/VoiceInk.app
	@echo "Installed /Applications/VoiceInk.app"
	@open /Applications/VoiceInk.app

clean:
	@echo "Cleaning project-local build artifacts..."
	@rm -rf "$(LOCAL_DERIVED_DATA)"
	@echo "Clean complete"

help:
	@echo "Available targets:"
	@echo "  check/healthcheck  Verify Xcode 27 and Swift toolchain"
	@echo "  list               List project schemes and targets"
	@echo "  destinations       List valid macOS destinations"
	@echo "  build/build-debug  Build unsigned Debug into .local-build"
	@echo "  build-release      Build unsigned Release into .local-build"
	@echo "  test/test-swift    Run VoiceInkTests (Swift Testing)"
	@echo "  test-ui            Run the full UI test target (guarded)"
	@echo "  test-ui-build      Compile UI tests without launching an app"
	@echo "  runtime-proof      Run the focused menu-bar launch proof (guarded)"
	@echo "  proof              Build Debug + Release and run Swift Testing"
	@echo "  local              Build signed Release in .local-build only"
	@echo "  run/run-local      Open only that project-local app (guarded)"
	@echo "  dev                Build, stop current VoiceInk, launch project-local app"
	@echo "  dev-restore        Stop local app and reopen /Applications/VoiceInk.app"
	@echo "  archive-stock      Explicitly archive /Applications/VoiceInk.app"
	@echo "  install            Explicitly replace /Applications/VoiceInk.app"
	@echo "  clean              Remove .local-build"
