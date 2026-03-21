PROJECT = Apps/LaplaceIME/LaplaceIME.xcodeproj
SCHEME = LaplaceIME
CONFIG = Debug
BUILD_DIR = $(CURDIR)/build
APP_NAME = LaplaceIME.app
INSTALL_DIR = $(HOME)/Library/Input Methods
QUIET_FLAG = $(if $(Q),-quiet)

.PHONY: build install clean test dict

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(BUILD_DIR) $(QUIET_FLAG) build

install: build
	-killall LaplaceIME 2>/dev/null
	@sleep 0.5
	rm -rf "$(INSTALL_DIR)/$(APP_NAME)"
	cp -R "$(BUILD_DIR)/Build/Products/$(CONFIG)/$(APP_NAME)" "$(INSTALL_DIR)/"
	@echo "Installed to $(INSTALL_DIR)/$(APP_NAME)"

clean:
	rm -rf $(BUILD_DIR)

test:
	cd Packages/PinyinEngine && swift test

dict:
	python3 tools/build_dict_db.py fixtures
