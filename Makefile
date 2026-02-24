# NotchNook — DMG Build System
# Usage:
#   make dmg                              Ad-hoc signed DMG (personal use)
#   make dmg SIGNING_IDENTITY="Dev ID..." Distribution signed DMG
#   make bundle                           Just build .app
#   make release                          Build DMG + create GitHub Release + update appcast
#   make generate-keys                    Generate Sparkle EdDSA signing keys (one-time)
#   make clean                            Remove build artifacts
#   make help                             Show all targets

# --- Configuration ---
APP_NAME        := NotchNook
BUNDLE_ID       := com.erikbartos.notchnook
VERSION         := $(shell cat VERSION)
BUILD_NUMBER    := $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
CONFIGURATION   := release

# Paths
BUILD_DIR       := .build/arm64-apple-macosx/$(CONFIGURATION)
DIST_DIR        := dist
BUILD_OUTPUT    := build
APP_BUNDLE      := $(BUILD_OUTPUT)/$(APP_NAME).app
DMG_OUTPUT      := $(BUILD_OUTPUT)/$(APP_NAME)-$(VERSION).dmg
DMG_STAGING     := $(BUILD_OUTPUT)/dmg-staging
EXECUTABLE      := $(BUILD_DIR)/notchnook

# Sparkle paths
SPARKLE_FRAMEWORK := $(BUILD_DIR)/Sparkle.framework
SIGN_UPDATE     := .build/artifacts/sparkle/Sparkle/bin/sign_update
GENERATE_KEYS   := .build/artifacts/sparkle/Sparkle/bin/generate_keys

# Sparkle EdDSA public key — set via env or leave empty to skip
SPARKLE_ED_KEY  ?=

# Signing — default ad-hoc (-), override for distribution
SIGNING_IDENTITY ?= -

# --- Targets ---
.PHONY: all build icon bundle sign dmg clean help release generate-keys

all: dmg ## Build everything and produce DMG

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

build: ## Compile release binary via SPM
	swift build -c $(CONFIGURATION)
	@echo "Built: $(EXECUTABLE)"

icon: ## Generate app icon (.icns)
	@mkdir -p $(BUILD_OUTPUT)
	bash scripts/create-icns.sh $(BUILD_OUTPUT)/AppIcon.icns

bundle: build icon ## Assemble .app bundle
	@echo "Assembling $(APP_BUNDLE)..."
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@mkdir -p $(APP_BUNDLE)/Contents/Frameworks
	@cp $(EXECUTABLE) $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	@cp $(DIST_DIR)/PkgInfo $(APP_BUNDLE)/Contents/
	@sed -e 's/$${VERSION}/$(VERSION)/g' \
	     -e 's/$${BUILD_NUMBER}/$(BUILD_NUMBER)/g' \
	     -e 's/$${SPARKLE_ED_KEY}/$(SPARKLE_ED_KEY)/g' \
	     $(DIST_DIR)/Info.plist > $(APP_BUNDLE)/Contents/Info.plist
	@cp $(BUILD_OUTPUT)/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
	@echo "Embedding Sparkle.framework..."
	@xattr -cr $(SPARKLE_FRAMEWORK)
	@COPYFILE_DISABLE=1 ditto $(SPARKLE_FRAMEWORK) $(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework
	@xattr -cr $(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework
	@install_name_tool -add_rpath @executable_path/../Frameworks $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME) 2>/dev/null || true
	@echo "Bundle assembled: $(APP_BUNDLE)"

sign: bundle ## Code-sign the .app bundle
	@echo "Signing with identity: $(SIGNING_IDENTITY)"
	@xattr -cr $(APP_BUNDLE)
	@find $(APP_BUNDLE) -name '._*' -delete 2>/dev/null || true
	@find $(APP_BUNDLE) -name '.DS_Store' -delete 2>/dev/null || true
	@# Sign Sparkle nested components inside-out
	codesign --force --options runtime --sign "$(SIGNING_IDENTITY)" \
		$(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc
	codesign --force --options runtime --sign "$(SIGNING_IDENTITY)" \
		$(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc
	codesign --force --options runtime --sign "$(SIGNING_IDENTITY)" \
		$(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app
	codesign --force --options runtime --sign "$(SIGNING_IDENTITY)" \
		$(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate
	codesign --force --options runtime --sign "$(SIGNING_IDENTITY)" \
		$(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework
	@# Clear any detritus before final sign
	@xattr -cr $(APP_BUNDLE)
	@find $(APP_BUNDLE) -name '._*' -delete 2>/dev/null || true
	@# Sign the main app
	codesign --force --options runtime \
		--entitlements $(DIST_DIR)/NotchNook.entitlements \
		--sign "$(SIGNING_IDENTITY)" \
		$(APP_BUNDLE)
	codesign --verify --verbose=2 $(APP_BUNDLE)
	@echo "Signing verified."

dmg: sign ## Create distributable DMG
	bash scripts/create-dmg.sh \
		"$(APP_BUNDLE)" \
		"$(DMG_OUTPUT)" \
		"$(APP_NAME)" \
		"$(DMG_STAGING)" \
		"$(SIGNING_IDENTITY)"

release: dmg ## Build DMG + create GitHub Release + update appcast
	bash scripts/release.sh "$(DMG_OUTPUT)" "$(VERSION)" "$(APP_NAME)"

generate-keys: ## Generate Sparkle EdDSA signing keys (one-time)
	@if [ -f "$(GENERATE_KEYS)" ]; then \
		$(GENERATE_KEYS); \
	else \
		echo "Error: generate_keys not found at $(GENERATE_KEYS)"; \
		echo "Run 'swift build -c release' first to fetch Sparkle artifacts."; \
		exit 1; \
	fi

clean: ## Remove all build artifacts
	rm -rf $(BUILD_OUTPUT)
	swift package clean
	@echo "Cleaned."
