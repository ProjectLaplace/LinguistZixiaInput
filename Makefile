.DEFAULT_GOAL := help

PROJECT = Apps/LaplaceIME/LaplaceIME.xcodeproj
SCHEME = LaplaceIME
CONFIG = Release
BUILD_DIR = $(CURDIR)/build
# Serialize agent-triggered Xcode builds through one shared DerivedData cache.
XCODEBUILD_LOCK = $(BUILD_DIR)/.xcodebuild.lock
XCODEBUILD = tools/with_xcodebuild_lock.sh $(XCODEBUILD_LOCK) xcodebuild
APP_NAME = Linguist Zixia Input.app
INSTALL_DIR = $(HOME)/Library/Input Methods
QUIET_FLAG = $(if $(V),,-quiet)
VERSION = $(shell git describe --tags --abbrev=0 2>/dev/null || echo v0.1.0)
VERSION_NUMBER = $(VERSION:v%=%)
ZIP_NAME = LinguistZixiaInput-$(VERSION).zip
DICT_DB = Packages/PinyinEngine/Sources/PinyinEngine/Resources/zh_dict.db

.PHONY: help bootstrap build install reload clean test dict dict-release dicts-all bundle-alt-dicts unbundle-alt-dicts eval-dicts eval-stability release dist format eval query list-user-words reset-user-words

TEST_RESOURCES = Packages/PinyinEngine/Tests/PinyinEngineTests/Resources

help: ## 显示所有可用目标及说明
	@echo "Usage: make <target>"
	@echo ""
	@echo "Targets:"
	@awk 'BEGIN {FS = ":[^#]*## "} /^[a-zA-Z_-]+:[^#]*## / {printf "  %-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# 准备开发环境：生成所有打包的词典文件，并清理废弃产物。
# 新 worktree / clean checkout 后执行一次即可。
# fixture 词典写到 test target 的 Resources（仅供单元测试加载），不再污染 production。
# production 暂用 fixture 版的 ja_dict 作为占位，等正式 ja preset 实现后替换。
bootstrap: ## 准备开发环境：初始化 submodule，生成所有打包词典
	@echo "==> Initializing submodules (rime-ice, rime-frost)..."
	tools/init_submodules.sh
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

# 默认采用 Release 配置：日常打字延迟更低、内存更小，且贴近终端用户体验。
# 调试崩溃或需触发 assert / assertionFailure 时切回 Debug：make install CONFIG=Debug
build: $(if $(MULTI_DICT),bundle-alt-dicts,unbundle-alt-dicts) ## 构建 IME（默认 Release；CONFIG=Debug 切换至 Debug；MULTI_DICT=1 同时打包额外词库供 ⌃⇧⌘D 切换）
	$(XCODEBUILD) -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(BUILD_DIR) $(QUIET_FLAG) $(XCFLAGS) build

install: build ## 构建并安装到系统输入法目录
	-killall "Linguist Zixia Input" 2>/dev/null
	@sleep 0.5
	rm -rf "$(INSTALL_DIR)/$(APP_NAME)"
	cp -R "$(BUILD_DIR)/Build/Products/$(CONFIG)/$(APP_NAME)" "$(INSTALL_DIR)/"
	@echo "Installed to $(INSTALL_DIR)/$(APP_NAME)"

LSREGISTER = /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# 让输入法 UI 代理重读 IME plist（图标、TISIconLabels 等），免去重启系统。
# lsregister -f 强制刷新 LaunchServices 数据库里的 bundle 信息，
# 然后重启 TextInputMenuAgent（菜单栏）、
# TextInputSwitcher（Ctrl-Space 输入源切换浮层）和 IME 进程本身。
reload: ## 重读 IME plist 与图标，无需重启系统
	-$(LSREGISTER) -f "$(INSTALL_DIR)/$(APP_NAME)" 2>/dev/null
	-killall TextInputMenuAgent 2>/dev/null
	-killall -9 TextInputSwitcher 2>/dev/null
	-killall "Linguist Zixia Input" 2>/dev/null
	@echo "Reloaded LaunchServices + TextInputMenuAgent + TextInputSwitcher"

clean: ## 删除 build/ 产物
	rm -rf $(BUILD_DIR)

$(DICT_DB):
	python3 tools/build_dict_db.py preset default

dict-release: ## 重新生成 production zh_dict
	rm -f "$(DICT_DB)"
	python3 tools/build_dict_db.py preset default

release: $(DICT_DB) unbundle-alt-dicts ## 构建 Release 并注入 MARKETING_VERSION
	$(XCODEBUILD) -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-derivedDataPath $(BUILD_DIR) $(QUIET_FLAG) $(XCFLAGS) \
		MARKETING_VERSION=$(VERSION_NUMBER) \
		build

dist: release ## 构建 Release 并打包为 ZIP
	ditto -c -k --keepParent \
		"$(BUILD_DIR)/Build/Products/Release/$(APP_NAME)" \
		"$(BUILD_DIR)/$(ZIP_NAME)"
	@echo "Archive created: $(BUILD_DIR)/$(ZIP_NAME)"

test: ## 运行引擎单元测试
	cd Packages/PinyinEngine && swift test

dict: ## 生成 fixture 词典
	python3 tools/build_dict_db.py fixtures

# ── 备用词库（放在 dicts/，不打包、不进 git，供 eval --dict 对比用）────
# make dicts-all          全部构建
# make dicts/zh_dict_frost_full.db   单独构建某一个（pattern rule 推导 source/preset）
ALT_DICTS = \
	dicts/zh_dict_ice_default.db \
	dicts/zh_dict_ice_full.db \
	dicts/zh_dict_frost_default.db \
	dicts/zh_dict_frost_full.db

dicts-all: $(ALT_DICTS) ## 构建所有备用词典（dicts/，不打包）

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

bundle-alt-dicts: $(BUNDLED_ALT_DICTS) ## 同步 alt 词典至 engine Resources/

unbundle-alt-dicts: ## 清除 engine Resources/ 内的额外词库（默认构建走此分支）
	rm -f $(BUNDLED_ALT_DICTS)

# ── 跨词库对比 ────────────────────────────────────────────────────────
# 对 shipped 词库 + dicts/ 下所有 .db 运行 pinyin-eval，输出通过率表 + case 矩阵。
eval-dicts: $(DICT_DB) $(ALT_DICTS) ## 跨词库对比测试
	python3 tools/eval_dicts.py $(DICT_DB) $(ALT_DICTS)

# ── 组合稳定性分析 ────────────────────────────────────────────────────
# 针对 shipped 词库跑 tools/eval_stability.py，把多段 case 分类为
# Composition Bug / Segment Artifact / Stable 等桶。传 DICT=<path> 换词库。
# 例：make eval-stability DICT=dicts/zh_dict_frost_default.db
eval-stability: $(DICT_DB) ## 组合稳定性分析（DICT=<path> 切换词库）
	python3 tools/eval_stability.py $(if $(DICT),--dict $(DICT),)

format: ## 格式化 Swift / Markdown
	swift-format format -i -r Packages/PinyinEngine/Sources Packages/PinyinEngine/Tests Apps/LaplaceIME/LaplaceIME
	prettier --write "**/*.md"

eval: ## 运行 Conversion 回归测试（CASE=<file> 指定用例文件）
ifdef CASE
	cd Packages/PinyinEngine && swift run pinyin-eval "$(CASE)"
else
	cd Packages/PinyinEngine && swift run pinyin-eval ../../fixtures/pinyin-strings.cases
endif

query: ## 单条 pinyin 查询（make query P=<pinyin>）
ifndef P
	$(error Usage: make query P=<pinyin>)
endif
	cd Packages/PinyinEngine && swift run pinyin-eval -q "$(P)"

USER_DICT = $(HOME)/Library/Application Support/LaplaceIME/user_dict.db

list-user-words: ## 列出用户词典条目
	sqlite3 "$(USER_DICT)" "SELECT * FROM user_entries"

reset-user-words: ## 删除用户词典
	rm -f "$(USER_DICT)"
	@echo "User dictionary removed: $(USER_DICT)"
