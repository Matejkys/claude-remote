# ClaudeRemote - macOS menu bar app build system
# Uses Swift Package Manager for compilation and creates a proper .app bundle

APP_NAME = ClaudeRemote
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CONTENTS_DIR = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS_DIR)/MacOS
INSTALL_DIR = /Applications

.PHONY: all build bundle install clean run

all: install

build:
	rm -rf .build
	swift build -c release

bundle: build
	mkdir -p $(MACOS_DIR)
	cp .build/release/$(APP_NAME) $(MACOS_DIR)/$(APP_NAME)
	cp Info.plist $(CONTENTS_DIR)/Info.plist
	codesign --force --sign - $(APP_BUNDLE)
	@echo "Built $(APP_BUNDLE)"

install: bundle
	rm -rf $(INSTALL_DIR)/$(APP_NAME).app
	cp -R $(APP_BUNDLE) $(INSTALL_DIR)/$(APP_NAME).app
	xattr -rc $(INSTALL_DIR)/$(APP_NAME).app
	@echo "✅ Installed to $(INSTALL_DIR)/$(APP_NAME).app"
	@echo ""
	@echo "🔑 Setting up keychain access..."
	@echo "   (prevents keychain prompts on every launch)"
	@echo ""
	@bash -c 'read -s -p "Enter your macOS password: " PASS; echo ""; \
		for ACCOUNT in telegram-bot-token telegram-user-id; do \
			if security find-generic-password -s "com.matejkys.ClaudeRemote" -a "$$ACCOUNT" >/dev/null 2>&1; then \
				echo "Setting ACL for $$ACCOUNT..."; \
				security set-generic-password-partition-list \
					-s "com.matejkys.ClaudeRemote" \
					-a "$$ACCOUNT" \
					-S -k "$$PASS" 2>/dev/null && echo "  ✅ Done" || echo "  ℹ️  Item not found yet (will be created on first use)"; \
			fi; \
		done; \
		echo ""; \
		echo "✅ Installation complete!"'

run: bundle
	open $(APP_BUNDLE)

clean:
	swift package clean
	rm -rf $(BUILD_DIR)
