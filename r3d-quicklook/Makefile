APP_NAME   := R3D Preview
PROJECT    := R3DQuickLook.xcodeproj
SCHEME     := R3D Preview
BUILD_DIR  := build
APP_PATH   := $(BUILD_DIR)/Build/Products/Release/$(APP_NAME).app
INSTALL_DIR ?= /Applications

.PHONY: project build test install reset clean sdk

project: ## Generate the Xcode project (needs: brew install xcodegen)
	@command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen"; exit 1; }
	xcodegen generate

build: project ## Release build into ./build
	xcodebuild -project $(PROJECT) -scheme "$(SCHEME)" -configuration Release \
	  -derivedDataPath $(BUILD_DIR) build

test: project ## Run unit tests
	xcodebuild -project $(PROJECT) -scheme "$(SCHEME)" -destination 'platform=macOS' \
	  -derivedDataPath $(BUILD_DIR) test

install: build ## Copy the app to /Applications, register the extensions, reset Quick Look
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	cp -R "$(APP_PATH)" "$(INSTALL_DIR)/"
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$(INSTALL_DIR)/$(APP_NAME).app"
	pluginkit -a "$(INSTALL_DIR)/$(APP_NAME).app/Contents/PlugIns/R3DPreviewExtension.appex"
	pluginkit -a "$(INSTALL_DIR)/$(APP_NAME).app/Contents/PlugIns/R3DThumbnailExtension.appex"
	$(MAKE) reset
	open "$(INSTALL_DIR)/$(APP_NAME).app"

reset: ## Reload Quick Look and clear its thumbnail cache
	qlmanage -r >/dev/null
	qlmanage -r cache >/dev/null
	killall Finder || true

sdk: ## Wire in the RED SDK: make sdk R3DSDK=~/Downloads/R3DSDKv8_x
	scripts/install-r3dsdk.sh "$(R3DSDK)"

clean:
	rm -rf $(BUILD_DIR) $(PROJECT)
