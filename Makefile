PROJECT = Apps/LaplaceIME/LaplaceIME.xcodeproj
SCHEME = LaplaceIME
CONFIG = Debug
BUILD_DIR = $(CURDIR)/build
APP_NAME = LaplaceIME.app
INSTALL_DIR = $(HOME)/Library/Input Methods
QUIET_FLAG = $(if $(Q),-quiet)

.PHONY: build install clean test dict format eval query list-user-words reset-user-words

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

format:
	swift-format format -i -r Packages/PinyinEngine/Sources Packages/PinyinEngine/Tests Apps/LaplaceIME/LaplaceIME
	prettier --write "**/*.md"

eval:
ifdef CASE
	cd Packages/PinyinEngine && swift run pinyin-eval "$(CASE)"
else
	cd Packages/PinyinEngine && swift run pinyin-eval ../../fixtures/pinyin-strings.cases
endif

query:
ifndef P
	$(error Usage: make query P=<pinyin>)
endif
	cd Packages/PinyinEngine && swift run pinyin-eval -q "$(P)"

USER_DICT = $(HOME)/Library/Application Support/LaplaceIME/user_dict.db

list-user-words:
	sqlite3 "$(USER_DICT)" "SELECT * FROM user_entries"

reset-user-words:
	rm -f "$(USER_DICT)"
	@echo "User dictionary removed: $(USER_DICT)"
