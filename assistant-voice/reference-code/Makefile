# Voice Client - Build & Package
# Run on macOS: make app

APP_NAME = AssistantVoice
BUNDLE_ID = com.example.voice-client
VERSION = 1.0.0

BUILD_DIR = .build/release
APP_BUNDLE = $(APP_NAME).app
CONTENTS = $(APP_BUNDLE)/Contents
MACOS = $(CONTENTS)/MacOS
RESOURCES = $(CONTENTS)/Resources

.PHONY: all build app clean install

all: app

# Build the Swift executable
build:
	swift build -c release

# Create the .app bundle
app: build
	@echo "Creating $(APP_BUNDLE)..."
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(MACOS)
	@mkdir -p $(RESOURCES)

	@# Copy binary
	@cp $(BUILD_DIR)/voice-client $(MACOS)/$(APP_NAME)

	@# Create Info.plist (LSUIElement = menu bar only, no dock icon)
	@echo '<?xml version="1.0" encoding="UTF-8"?>' > $(CONTENTS)/Info.plist
	@echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' >> $(CONTENTS)/Info.plist
	@echo '<plist version="1.0">' >> $(CONTENTS)/Info.plist
	@echo '<dict>' >> $(CONTENTS)/Info.plist
	@echo '    <key>CFBundleExecutable</key>' >> $(CONTENTS)/Info.plist
	@echo '    <string>$(APP_NAME)</string>' >> $(CONTENTS)/Info.plist
	@echo '    <key>CFBundleIdentifier</key>' >> $(CONTENTS)/Info.plist
	@echo '    <string>$(BUNDLE_ID)</string>' >> $(CONTENTS)/Info.plist
	@echo '    <key>CFBundleName</key>' >> $(CONTENTS)/Info.plist
	@echo '    <string>$(APP_NAME)</string>' >> $(CONTENTS)/Info.plist
	@echo '    <key>CFBundleDisplayName</key>' >> $(CONTENTS)/Info.plist
	@echo '    <string>Assistant Voice</string>' >> $(CONTENTS)/Info.plist
	@echo '    <key>CFBundleVersion</key>' >> $(CONTENTS)/Info.plist
	@echo '    <string>$(VERSION)</string>' >> $(CONTENTS)/Info.plist
	@echo '    <key>CFBundleShortVersionString</key>' >> $(CONTENTS)/Info.plist
	@echo '    <string>$(VERSION)</string>' >> $(CONTENTS)/Info.plist
	@echo '    <key>CFBundlePackageType</key>' >> $(CONTENTS)/Info.plist
	@echo '    <string>APPL</string>' >> $(CONTENTS)/Info.plist
	@echo '    <key>LSMinimumSystemVersion</key>' >> $(CONTENTS)/Info.plist
	@echo '    <string>12.0</string>' >> $(CONTENTS)/Info.plist
	@echo '    <key>LSUIElement</key>' >> $(CONTENTS)/Info.plist
	@echo '    <true/>' >> $(CONTENTS)/Info.plist
	@echo '    <key>NSHighResolutionCapable</key>' >> $(CONTENTS)/Info.plist
	@echo '    <true/>' >> $(CONTENTS)/Info.plist
	@echo '    <key>CFBundleIconFile</key>' >> $(CONTENTS)/Info.plist
	@echo '    <string>AppIcon</string>' >> $(CONTENTS)/Info.plist
	@echo '</dict>' >> $(CONTENTS)/Info.plist
	@echo '</plist>' >> $(CONTENTS)/Info.plist

	@# Copy icon if exists
	@if [ -f AppIcon.icns ]; then \
		cp AppIcon.icns $(RESOURCES)/AppIcon.icns; \
		echo "Added app icon"; \
	fi

	@# Ad-hoc code sign
	@echo "Signing $(APP_BUNDLE)..."
	@codesign --force --deep -s - $(APP_BUNDLE)

	@echo ""
	@echo "Done! $(APP_BUNDLE) created."
	@echo "To install: make install"
	@echo "To run: open $(APP_BUNDLE)"

# Install to /Applications
install: app
	@echo "Installing to /Applications..."
	@rm -rf /Applications/$(APP_BUNDLE)
	@cp -R $(APP_BUNDLE) /Applications/
	@echo "Installed! Run from Applications folder or Spotlight."

# Clean build artifacts
clean:
	@rm -rf .build $(APP_BUNDLE)
	@echo "Cleaned."
