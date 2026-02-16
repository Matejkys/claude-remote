# ClaudeRemote - macOS menu bar app build system
# Uses Swift Package Manager for compilation and creates a proper .app bundle

APP_NAME = ClaudeRemote
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CONTENTS_DIR = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS_DIR)/MacOS
INSTALL_DIR = /Applications

.PHONY: all build bundle install clean run

all: bundle

build:
	swift build -c release

bundle: build
	mkdir -p $(MACOS_DIR)
	cp .build/release/$(APP_NAME) $(MACOS_DIR)/$(APP_NAME)
	cp Info.plist $(CONTENTS_DIR)/Info.plist
	codesign --force --sign - $(APP_BUNDLE)
	@echo "Built $(APP_BUNDLE)"

install: bundle
	cp -R $(APP_BUNDLE) $(INSTALL_DIR)/$(APP_NAME).app
	xattr -rc $(INSTALL_DIR)/$(APP_NAME).app
	@echo "Installed to $(INSTALL_DIR)/$(APP_NAME).app"

run: bundle
	open $(APP_BUNDLE)

clean:
	swift package clean
	rm -rf $(BUILD_DIR)
