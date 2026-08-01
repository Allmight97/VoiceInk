LOCAL_DERIVED_DATA := $(CURDIR)/.local-build

# Stable local signing identity so TCC permission grants survive rebuilds.
# Created once via: openssl self-signed cert imported to the login keychain.
LOCAL_SIGN_IDENTITY := VoiceInk Local

# If xcode-select points at CommandLineTools, fall back to Xcode(-beta).app
ifneq ($(shell xcodebuild -version >/dev/null 2>&1 && echo ok),ok)
  ifneq ($(wildcard /Applications/Xcode-beta.app),)
    export DEVELOPER_DIR := /Applications/Xcode-beta.app/Contents/Developer
  else ifneq ($(wildcard /Applications/Xcode.app),)
    export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
  endif
endif

.PHONY: all clean build local check healthcheck help dev run install archive-stock

# Default target
all: check build

# Development workflow
dev: build run

# Prerequisites
check:
	@echo "Checking prerequisites..."
	@command -v git >/dev/null 2>&1 || { echo "git is not installed"; exit 1; }
	@command -v xcodebuild >/dev/null 2>&1 || { echo "xcodebuild is not installed (need Xcode)"; exit 1; }
	@command -v swift >/dev/null 2>&1 || { echo "swift is not installed"; exit 1; }
	@echo "Prerequisites OK"

healthcheck: check

build: check
	xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug CODE_SIGN_IDENTITY="" build

# Build for local use without Apple Developer certificate
local: check
	@echo "Building VoiceInk for local use (no Apple Developer certificate required)..."
	@rm -rf "$(LOCAL_DERIVED_DATA)"
	xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Release \
		-derivedDataPath "$(LOCAL_DERIVED_DATA)" \
		-xcconfig LocalBuild.xcconfig \
		CODE_SIGN_IDENTITY="$(LOCAL_SIGN_IDENTITY)" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=YES \
		DEVELOPMENT_TEAM="" \
		CODE_SIGN_ENTITLEMENTS="$(CURDIR)/VoiceInk/VoiceInk.local.entitlements" \
		SWIFT_ACTIVE_COMPILATION_CONDITIONS='$$(inherited) LOCAL_BUILD' \
		build
	@APP_PATH="$(LOCAL_DERIVED_DATA)/Build/Products/Release/VoiceInk.app" && \
	if [ -d "$$APP_PATH" ]; then \
		echo "Copying VoiceInk.app to ~/Downloads..."; \
		rm -rf "$$HOME/Downloads/VoiceInk.app"; \
		ditto "$$APP_PATH" "$$HOME/Downloads/VoiceInk.app"; \
		xattr -cr "$$HOME/Downloads/VoiceInk.app"; \
		echo ""; \
		echo "Build complete! App saved to: ~/Downloads/VoiceInk.app"; \
		echo "Run with: open ~/Downloads/VoiceInk.app"; \
		echo ""; \
		echo "Limitations of local builds:"; \
		echo "  - No iCloud dictionary sync"; \
		echo "  - No automatic updates (pull new code and rebuild to update)"; \
	else \
		echo "Error: Could not find built VoiceInk.app at $$APP_PATH"; \
		exit 1; \
	fi

# One-time backup of whatever is currently installed in /Applications
archive-stock:
	@if [ -d "/Applications/VoiceInk.app" ]; then \
		V=$$(defaults read /Applications/VoiceInk.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo unknown); \
		OUT="$$HOME/Downloads/VoiceInk-$$V-backup.zip"; \
		ditto -c -k --keepParent /Applications/VoiceInk.app "$$OUT"; \
		echo "Archived /Applications/VoiceInk.app -> $$OUT"; \
	else \
		echo "No /Applications/VoiceInk.app to archive"; \
	fi

# Build and install into /Applications (quits any running copy first)
install: local
	-@osascript -e 'tell application "VoiceInk" to quit' 2>/dev/null; sleep 2
	@rm -rf /Applications/VoiceInk.app
	@ditto "$(LOCAL_DERIVED_DATA)/Build/Products/Release/VoiceInk.app" /Applications/VoiceInk.app
	@xattr -cr /Applications/VoiceInk.app
	@echo "Installed /Applications/VoiceInk.app"
	@open /Applications/VoiceInk.app

# Run application
run:
	@if [ -d "$$HOME/Downloads/VoiceInk.app" ]; then \
		echo "Opening ~/Downloads/VoiceInk.app..."; \
		open "$$HOME/Downloads/VoiceInk.app"; \
	else \
		echo "Looking for VoiceInk.app in DerivedData..."; \
		APP_PATH=$$(find "$$HOME/Library/Developer/Xcode/DerivedData" -name "VoiceInk.app" -type d | head -1) && \
		if [ -n "$$APP_PATH" ]; then \
			echo "Found app at: $$APP_PATH"; \
			open "$$APP_PATH"; \
		else \
			echo "VoiceInk.app not found. Please run 'make build' or 'make local' first."; \
			exit 1; \
		fi; \
	fi

# Cleanup
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf "$(LOCAL_DERIVED_DATA)"
	@echo "Clean complete"

# Help
help:
	@echo "Available targets:"
	@echo "  check/healthcheck  Check if required CLI tools are installed"
	@echo "  build              Debug build, unsigned (compiles, may not launch)"
	@echo "  local              Release build, self-signed -> ~/Downloads/VoiceInk.app"
	@echo "  install            local, then install to /Applications and launch"
	@echo "  run                Launch the built VoiceInk app"
	@echo "  dev                Build and run the app (for development)"
	@echo "  all                check + build (default)"
	@echo "  archive-stock      Back up whatever is in /Applications/VoiceInk.app"
	@echo "  clean              Remove build artifacts"
	@echo "  help               Show this help message"
	@echo ""
	@echo "Use 'make local' or 'make install' for anything you intend to run:"
	@echo "Debug builds lose TCC permission grants. See BUILDING.md."
