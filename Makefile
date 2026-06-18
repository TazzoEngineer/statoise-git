.PHONY: generate build run clean dmg

PROJECT_DIR = TortoiseGitMac
PROJECT = $(PROJECT_DIR)/TortoiseGitMac.xcodeproj
SCHEME = TortoiseGitMac
CONFIGURATION ?= Debug
BUILD_DIR = build
DERIVED_DATA = $(BUILD_DIR)/DerivedData
APP_NAME = TortoiseGitMac

# Generate Xcode project from project.yml
generate:
	cd $(PROJECT_DIR) && xcodegen generate

# Build the app
build: generate
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA) \
		build

# Build release
release: CONFIGURATION = Release
release: build

# Run the app
run: build
	open $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(APP_NAME).app

# Create DMG for distribution
dmg: release
	@./scripts/create-dmg.sh "$(DERIVED_DATA)/Build/Products/Release/$(APP_NAME).app" $(BUILD_DIR)

# Archive for distribution (with code signing)
archive: generate
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Release \
		-archivePath $(BUILD_DIR)/$(APP_NAME).xcarchive \
		archive

# Clean build artifacts
clean:
	rm -rf $(BUILD_DIR)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean 2>/dev/null || true
