PREFIX ?= $(HOME)/.local
APP_NAME = Larimar.app
BUILD_DIR = .build/release
BUNDLE_DIR = $(BUILD_DIR)/$(APP_NAME)
VERSION := $(shell cat VERSION)

.PHONY: all build bundle install uninstall clean check-version

all: bundle

check-version:
	@v=$$(cat VERSION); \
	actual_swift=$$(grep 'current = ' Sources/LarimarShared/Version.swift | sed 's/.*"\(.*\)".*/\1/'); \
	if [ "$$actual_swift" != "$$v" ]; then \
		echo "Version.swift ($$actual_swift) != VERSION ($$v)" >&2; exit 1; \
	fi; \
	actual_plist=$$(/usr/bin/plutil -extract CFBundleShortVersionString raw Resources/Info.plist); \
	if [ "$$actual_plist" != "$$v" ]; then \
		echo "Info.plist ($$actual_plist) != VERSION ($$v)" >&2; exit 1; \
	fi; \
	echo "Version $$v is consistent"

build: check-version
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
