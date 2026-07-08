APP_NAME := MayStock
BUNDLE_ID := com.maystock.app
INSTALL_DIR := /Applications
APP_BUNDLE := $(INSTALL_DIR)/$(APP_NAME).app
BUILD_DIR := .build/release
EXECUTABLE := $(BUILD_DIR)/$(APP_NAME)
INFO_PLIST := Sources/MayStock/SupportingFiles/Info.plist
ICON_DIR := Sources/MayStock/Resources/Assets.xcassets/AppIcon.appiconset

.PHONY: build install run clean uninstall

build:
	swift build -c release

install: build
	@echo "Creating $(APP_BUNDLE)..."
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@cp $(EXECUTABLE) "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	@cp $(INFO_PLIST) "$(APP_BUNDLE)/Contents/Info.plist"
	@# Build icns from the icon PNGs
	@mkdir -p /tmp/MayStock.iconset
	@cp "$(ICON_DIR)/icon_16x16.png" /tmp/MayStock.iconset/icon_16x16.png
	@cp "$(ICON_DIR)/icon_16x16@2x.png" /tmp/MayStock.iconset/icon_16x16@2x.png
	@cp "$(ICON_DIR)/icon_32x32.png" /tmp/MayStock.iconset/icon_32x32.png
	@cp "$(ICON_DIR)/icon_32x32@2x.png" /tmp/MayStock.iconset/icon_32x32@2x.png
	@cp "$(ICON_DIR)/icon_128x128.png" /tmp/MayStock.iconset/icon_128x128.png
	@cp "$(ICON_DIR)/icon_128x128@2x.png" /tmp/MayStock.iconset/icon_128x128@2x.png
	@cp "$(ICON_DIR)/icon_256x256.png" /tmp/MayStock.iconset/icon_256x256.png
	@cp "$(ICON_DIR)/icon_256x256@2x.png" /tmp/MayStock.iconset/icon_256x256@2x.png
	@cp "$(ICON_DIR)/icon_512x512.png" /tmp/MayStock.iconset/icon_512x512.png
	@cp "$(ICON_DIR)/icon_512x512@2x.png" /tmp/MayStock.iconset/icon_512x512@2x.png
	@iconutil -c icns /tmp/MayStock.iconset -o "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"
	@rm -rf /tmp/MayStock.iconset
	@# Copy bundled resources if they exist
	@if [ -d "$(BUILD_DIR)/MayStock_MayStock.bundle" ]; then \
		cp -R "$(BUILD_DIR)/MayStock_MayStock.bundle" "$(APP_BUNDLE)/Contents/Resources/"; \
	fi
	@# Set icon in Info.plist
	@/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$(APP_BUNDLE)/Contents/Info.plist" 2>/dev/null || \
		/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$(APP_BUNDLE)/Contents/Info.plist"
	@echo "Installed to $(APP_BUNDLE)"

run: install
	@echo "Launching $(APP_NAME)..."
	@open "$(APP_BUNDLE)"

clean:
	swift package clean
	rm -rf "$(APP_BUNDLE)"

uninstall:
	rm -rf "$(APP_BUNDLE)"
	@echo "Uninstalled $(APP_NAME)"
