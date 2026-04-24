PROJECT = Apps/LaplaceIME/LaplaceIME.xcodeproj
SCHEME = LaplaceIME
CONFIG = Debug
BUILD_DIR = $(CURDIR)/build
APP_NAME = Linguist Zixia Input.app
INSTALL_DIR = $(HOME)/Library/Input Methods
QUIET_FLAG = $(if $(V),,-quiet)
VERSION = $(shell git describe --tags --abbrev=0 2>/dev/null || echo v0.1.0)
VERSION_NUMBER = $(VERSION:v%=%)
ZIP_NAME = LinguistZixiaInput-$(VERSION).zip
DICT_DB = Packages/PinyinEngine/Sources/PinyinEngine/Resources/zh_dict.db

.PHONY: build install clean test dict dict-release dicts-all release dist format eval query list-user-words reset-user-words

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(BUILD_DIR) $(QUIET_FLAG) build

install: build
	-killall "Linguist Zixia Input" 2>/dev/null
	@sleep 0.5
	rm -rf "$(INSTALL_DIR)/$(APP_NAME)"
	cp -R "$(BUILD_DIR)/Build/Products/$(CONFIG)/$(APP_NAME)" "$(INSTALL_DIR)/"
	@echo "Installed to $(INSTALL_DIR)/$(APP_NAME)"

clean:
	rm -rf $(BUILD_DIR)

$(DICT_DB):
	python3 tools/build_dict_db.py preset default

dict-release:
	rm -f "$(DICT_DB)"
	python3 tools/build_dict_db.py preset default

release: $(DICT_DB)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-derivedDataPath $(BUILD_DIR) $(QUIET_FLAG) \
		MARKETING_VERSION=$(VERSION_NUMBER) \
		build

dist: release
	ditto -c -k --keepParent \
		"$(BUILD_DIR)/Build/Products/Release/$(APP_NAME)" \
		"$(BUILD_DIR)/$(ZIP_NAME)"
	@echo "Archive created: $(BUILD_DIR)/$(ZIP_NAME)"

test:
	cd Packages/PinyinEngine && swift test

dict:
	python3 tools/build_dict_db.py fixtures

# ── 备用词库（放在 dicts/，不打包、不进 git，供 eval --dict 对比用）────
# make dicts-all          全部构建
# make dicts/zh_dict_frost_full.db   单独构建某一个（pattern rule 推导 source/preset）
ALT_DICTS = \
	dicts/zh_dict_ice_default.db \
	dicts/zh_dict_ice_full.db \
	dicts/zh_dict_frost_default.db \
	dicts/zh_dict_frost_full.db

dicts-all: $(ALT_DICTS)

dicts/zh_dict_ice_%.db:
	python3 tools/build_dict_db.py preset $* --source ice -o $@

dicts/zh_dict_frost_%.db:
	python3 tools/build_dict_db.py preset $* --source frost -o $@

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
