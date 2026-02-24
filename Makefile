# NotchNook — DMG Build System
# Usage:
#   make dmg                              Ad-hoc signed DMG (personal use)
#   make dmg SIGNING_IDENTITY="Dev ID..." Distribution signed DMG
#   make bundle                           Just build .app
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

# Signing — default ad-hoc (-), override for distribution
SIGNING_IDENTITY ?= -

# --- Targets ---
.PHONY: all build icon bundle sign dmg clean help

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
	@cp $(EXECUTABLE) $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	@cp $(DIST_DIR)/PkgInfo $(APP_BUNDLE)/Contents/
	@sed -e 's/$${VERSION}/$(VERSION)/g' \
	     -e 's/$${BUILD_NUMBER}/$(BUILD_NUMBER)/g' \
	     $(DIST_DIR)/Info.plist > $(APP_BUNDLE)/Contents/Info.plist
	@cp $(BUILD_OUTPUT)/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
	@echo "Bundle assembled: $(APP_BUNDLE)"

sign: bundle ## Code-sign the .app bundle
	@echo "Signing with identity: $(SIGNING_IDENTITY)"
	codesign --force --deep --options runtime \
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

clean: ## Remove all build artifacts
	rm -rf $(BUILD_OUTPUT)
	swift package clean
	@echo "Cleaned."
