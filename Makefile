PREFIX ?= $(HOME)/.local
APP_NAME = Larimar.app
BUILD_DIR = .build/release
BUNDLE_DIR = $(BUILD_DIR)/$(APP_NAME)

.PHONY: all build bundle install uninstall clean

all: bundle

build:
	swift build -c release

bundle: build
	rm -rf $(BUNDLE_DIR)
	mkdir -p $(BUNDLE_DIR)/Contents/MacOS
	mkdir -p $(BUNDLE_DIR)/Contents/Resources
	cp $(BUILD_DIR)/LarimarDaemon $(BUNDLE_DIR)/Contents/MacOS/LarimarDaemon
	cp Resources/Info.plist $(BUNDLE_DIR)/Contents/Info.plist
	cp Resources/AppIcon.icns $(BUNDLE_DIR)/Contents/Resources/AppIcon.icns

install: bundle
	mkdir -p ~/Applications
	cp -R $(BUNDLE_DIR) ~/Applications/$(APP_NAME)
	mkdir -p $(PREFIX)/bin
	cp $(BUILD_DIR)/larimar $(PREFIX)/bin/larimar
	@echo "Installed Larimar.app to ~/Applications and larimar CLI to $(PREFIX)/bin"

uninstall:
	rm -rf ~/Applications/$(APP_NAME)
	rm -f $(PREFIX)/bin/larimar
	rm -rf ~/Library/Application\ Support/Larimar
	@echo "Uninstalled Larimar"

clean:
	swift package clean
	rm -rf $(BUNDLE_DIR)
