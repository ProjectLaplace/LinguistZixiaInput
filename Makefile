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

.PHONY: bootstrap build install reload clean test dict dict-release dicts-all bundle-alt-dicts eval-dicts eval-stability release dist format eval query list-user-words reset-user-words

TEST_RESOURCES = Packages/PinyinEngine/Tests/PinyinEngineTests/Resources

# 一键准备开发环境：生成所有打包的词典文件，并清理废弃产物。
# 新 worktree / clean checkout 后跑一次即可。
# fixture 词典写到 test target 的 Resources（仅供单元测试加载），不再污染 production。
# production 暂用 fixture 版的 ja_dict 作为占位，等正式 ja preset 实现后替换。
bootstrap:
	@echo "==> Generating fixture dictionaries into test resources..."
	python3 tools/build_dict_db.py fixtures
	@echo "==> Generating default zh_dict (rime-ice default preset) into production resources..."
	python3 tools/build_dict_db.py preset default
	@echo "==> Seeding production ja_dict from fixture (no ja preset yet)..."
	cp $(TEST_RESOURCES)/ja_dict.db $(ENGINE_RESOURCES)/ja_dict.db
	@echo "==> Generating and bundling alt dict variants..."
	$(MAKE) bundle-alt-dicts
	@rm -f $(ENGINE_RESOURCES)/zh_dict_unispim.db
	@echo "==> Bootstrap complete"

build: bundle-alt-dicts
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(BUILD_DIR) $(QUIET_FLAG) build

install: build
	-killall "Linguist Zixia Input" 2>/dev/null
	@sleep 0.5
	rm -rf "$(INSTALL_DIR)/$(APP_NAME)"
	cp -R "$(BUILD_DIR)/Build/Products/$(CONFIG)/$(APP_NAME)" "$(INSTALL_DIR)/"
	@echo "Installed to $(INSTALL_DIR)/$(APP_NAME)"

LSREGISTER = /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# 让菜单栏代理重读 IME plist（图标、TISIconLabels 等），免去重启系统。
# lsregister -f 强制刷新 LaunchServices 数据库里的 bundle 信息，
# 然后重启 TextInputMenuAgent（菜单栏渲染）和 IME 进程本身。
reload:
	-$(LSREGISTER) -f "$(INSTALL_DIR)/$(APP_NAME)" 2>/dev/null
	-killall TextInputMenuAgent 2>/dev/null
	-killall "Linguist Zixia Input" 2>/dev/null
	@echo "Reloaded LaunchServices + TextInputMenuAgent"

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

# ── 把 alt 词典同步到 engine Resources/（供 ⌃⇧⌘D 运行时切换使用）──
# shipped zh_dict.db 本身即 ice default 变体，其余三个额外打包进 app bundle。
ENGINE_RESOURCES = Packages/PinyinEngine/Sources/PinyinEngine/Resources
BUNDLED_ALT_DICTS = \
	$(ENGINE_RESOURCES)/zh_dict_ice_full.db \
	$(ENGINE_RESOURCES)/zh_dict_frost_default.db \
	$(ENGINE_RESOURCES)/zh_dict_frost_full.db

$(ENGINE_RESOURCES)/zh_dict_%.db: dicts/zh_dict_%.db
	cp $< $@

bundle-alt-dicts: $(BUNDLED_ALT_DICTS)

# ── 跨词库对比 ────────────────────────────────────────────────────────
# 对 shipped 词库 + dicts/ 下所有 .db 跑 pinyin-eval，输出通过率表 + case 矩阵。
eval-dicts: $(DICT_DB) $(ALT_DICTS)
	python3 tools/eval_dicts.py $(DICT_DB) $(ALT_DICTS)

# ── 组合稳定性分析 ────────────────────────────────────────────────────
# 针对 shipped 词库跑 tools/eval_stability.py，把多段 case 分类为
# Composition Bug / Segment Artifact / Stable 等桶。传 DICT=<path> 换词库。
# 例：make eval-stability DICT=dicts/zh_dict_frost_default.db
eval-stability: $(DICT_DB)
	python3 tools/eval_stability.py $(if $(DICT),--dict $(DICT),)

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
