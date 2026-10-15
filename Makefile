# Harbor developer commands. Run `make help` for the list.

PROJECT     := Harbor.xcodeproj
SCHEME      := Harbor
DERIVED     := build/DerivedData
APP_DEBUG   := $(DERIVED)/Build/Products/Debug/Harbor.app
XCODE_FLAGS := -skipPackagePluginValidation -skipMacroValidation

.PHONY: help bootstrap project build run test release clean icon web-vendor

help: ## Show this help
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

bootstrap: ## Install build tools (XcodeGen) and Xcode's first-launch components
	@command -v xcodegen >/dev/null || brew install xcodegen
	@xcodebuild -runFirstLaunch

project: ## Generate Harbor.xcodeproj from project.yml
	xcodegen generate

build: project ## Build a Debug app into build/DerivedData
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) \
		-destination 'platform=macOS,arch=arm64' $(XCODE_FLAGS) build -quiet

run: build ## Build and launch the Debug app
	open $(APP_DEBUG)

test: ## Run every unit and integration test (no Xcode project needed)
	cd Packages/HarborKit && swift test

release: ## Archive, sign with Developer ID, notarize and package a DMG (see Scripts/release.sh)
	Scripts/release.sh

icon: ## Regenerate the app icon
	swift Scripts/make-icon.swift App/Resources/Assets.xcassets/AppIcon.appiconset

web-vendor: ## Refresh the vendored xterm.js for the browser dashboard
	Scripts/fetch-web-vendor.sh

clean: ## Remove build output
	rm -rf build $(PROJECT) Packages/HarborKit/.build
