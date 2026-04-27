# IMK 菜单图标维护说明

本文记录 macOS IMK 输入法菜单图标的工程约束。该图标同时影响菜单栏输入法图标、输入源菜单、Ctrl-Space 输入源切换浮层，以及部分系统输入源列表。macOS 对这些资源存在多层缓存，且不同 UI 组件读取的 key 不完全一致，因此图标修改必须同时维护 plist、源 SVG、生成脚本与最终 bundle 资源。

## 当前方案

当前项目采用 PDF 资源路线：

- 源文件：`docs/assets/menu-icon-zh.svg`
- 生成脚本：`tools/make_menuicon_pdf.sh`
- bundle 资源：`Apps/LaplaceIME/LaplaceIME/MenuIconHans.pdf`
- plist 引用：`Apps/LaplaceIME/LaplaceIME/Info.plist`

`Info.plist` 中以下四个 key 必须保持一致，当前均指向 `MenuIconHans.pdf`：

```xml
<key>tsInputMethodIconFileKey</key>
<string>MenuIconHans.pdf</string>

<key>tsInputModeMenuIconFileKey</key>
<string>MenuIconHans.pdf</string>

<key>tsInputModeAlternateMenuIconFileKey</key>
<string>MenuIconHans.pdf</string>

<key>tsInputModePaletteIconFileKey</key>
<string>MenuIconHans.pdf</string>
```

其中 `tsInputModeAlternateMenuIconFileKey` 与 Ctrl-Space 输入源切换浮层有关。修改菜单栏图标时不能只检查 `tsInputMethodIconFileKey` 或 `tsInputModeMenuIconFileKey`。

## 尺寸要求

`MenuIconHans.pdf` 的 PDF `MediaBox` 必须为 `22×16 pt`：

```text
/MediaBox [ 0 0 22 16 ]
```

该尺寸来自对参考输入法资源的实测：

- Squirrel `rime.pdf`：`22×16 pt`
- Fcitx5 `menu_icon.pdf`：约 `21.75×15.75 pt`

如果 SVG 写成 `width="26" height="18"` 这类无单位尺寸，`rsvg-convert` 会按 px 解释，再以 96 dpi 转换为 PDF point，最终得到 `19.5×13.5 pt`。这会导致图标在系统 UI 中整体偏小。因此生成 PDF 时必须显式指定 point 尺寸：

```bash
rsvg-convert \
    -f pdf \
    --page-width=22pt \
    --page-height=16pt \
    -w 22pt \
    -h 16pt \
    -o Apps/LaplaceIME/LaplaceIME/MenuIconHans.pdf \
    docs/assets/menu-icon-zh.svg
```

实际维护时应使用：

```bash
tools/make_menuicon_pdf.sh
```

## SVG 源文件要求

`docs/assets/menu-icon-zh.svg` 必须保持为纯向量轮廓。为了避免字体依赖、透明材质、mask 导出差异和系统菜单高亮异常，源文件不得包含下列结构：

- `<text>`
- `<mask>` 或 `mask=`
- `opacity`
- `filter`
- `clipPath`
- `linearGradient` / `radialGradient`
- `<image>`

当前 SVG 使用单个 black compound path，并通过 `fill-rule="evenodd"` 表示镂空的括号和「紫」字轮廓。汉字必须预先转换为 path，不能依赖运行时字体渲染。

生成脚本会检查这些禁用结构：

```bash
rg -n '(<text|<mask|mask=|opacity|filter|clipPath|linearGradient|radialGradient|<image)' docs/assets/menu-icon-zh.svg
```

无输出才符合当前约束。

## 不采用的旧方案

### TIFF template 路线

旧方案使用 `MenuIconHansTemplate.tiff`，并配合 `TISIconIsTemplate`、`TISIconLabels` 或类似 key 交给系统渲染 template image。该路线已经废弃。

原因：

1. template image 与 label 渲染由系统控制，不同菜单场景中的选中态、反色和高亮行为不稳定。
2. Ctrl-Space 浮层与菜单栏可能走不同缓存和渲染路径，调试成本高。
3. 当前 PDF 路线与 Squirrel、Fcitx5 的输入模式图标策略更接近，行为更可控。

因此：

- `MenuIconHansTemplate.tiff` 不应再作为 plist icon key 的目标。
- `TISIconIsTemplate` 不应重新加入当前方案。
- `TISIconLabels` 不应作为当前图标渲染依赖。

### `MenuIconHansCustom.pdf` / `MenuIconHansV2.pdf`

这些名称只属于调试或缓存验证阶段，不应作为长期资源名。正式资源名保持为：

```text
MenuIconHans.pdf
```

如果为了验证系统缓存而临时更换文件名，验证后必须恢复正式名称，并确认 bundle 中没有残留临时 PDF。

## 缓存与刷新

macOS 输入法图标缓存非常顽固。以下命令可以刷新一部分系统状态，但不能保证刷新所有 UI 场景：

```bash
make reload
```

该目标会执行：

- `lsregister -f`：刷新 LaunchServices 中的 app bundle 信息。
- 重启 `TextInputMenuAgent`：菜单栏输入法 UI。
- 重启 `TextInputSwitcher`：Ctrl-Space 输入源切换浮层。
- 重启输入法进程本身。

经验结论：

1. 菜单栏与 Ctrl-Space 浮层可能由不同进程持有旧图标。
2. `TextInputSwitcher` 与 `TextInputMenuAgent` 重启后仍可能看到旧资源。
3. `cfprefsd` 与 `lsregister` 刷新不一定能清除所有图标缓存。
4. 如果资源文件名、plist、bundle 内容都已确认正确，但 UI 仍显示旧图标，重启系统可能是唯一可靠验证方式。

判断问题是否属于缓存时，应先验证安装后的 bundle，而不是只观察系统 UI。

## 验证清单

生成图标后执行：

```bash
tools/make_menuicon_pdf.sh
```

验证 PDF 尺寸：

```bash
/opt/homebrew/bin/mutool show Apps/LaplaceIME/LaplaceIME/MenuIconHans.pdf 2
```

输出中必须包含：

```text
/MediaBox [ 0 0 22 16 ]
```

验证 SVG 没有禁用结构：

```bash
rg -n '(<text|<mask|mask=|opacity|filter|clipPath|linearGradient|radialGradient|<image)' docs/assets/menu-icon-zh.svg
```

验证 plist 引用：

```bash
plutil -p Apps/LaplaceIME/LaplaceIME/Info.plist | rg 'MenuIcon|IconFileKey'
```

安装后验证 bundle：

```bash
make install CONFIG=Debug
make reload

plutil -p "$HOME/Library/Input Methods/Linguist Zixia Input.app/Contents/Info.plist" | rg 'MenuIcon|IconFileKey'
find "$HOME/Library/Input Methods/Linguist Zixia Input.app/Contents/Resources" -maxdepth 1 -type f -name 'MenuIconHans*' -print
```

期望结果：

1. plist 中四个 icon key 均指向 `MenuIconHans.pdf`。
2. bundle 中存在 `MenuIconHans.pdf`。
3. bundle 中不存在临时调试资源，例如 `MenuIconHansV2.pdf`。
4. 如已删除旧 TIFF 路线，bundle 中不应再包含 `MenuIconHansTemplate.tiff`。

## 修改流程

修改菜单图标时按以下顺序操作：

1. 修改 `docs/assets/menu-icon-zh.svg`。
2. 确认 SVG 不包含禁用结构。
3. 执行 `tools/make_menuicon_pdf.sh` 生成 `MenuIconHans.pdf`。
4. 用 `mutool show` 确认 PDF `MediaBox` 为 `22×16 pt`。
5. 确认 `Info.plist` 四个 icon key 都指向 `MenuIconHans.pdf`。
6. 执行 `make install CONFIG=Debug` 与 `make reload`。
7. 检查安装后的 bundle plist 与 resources。
8. 若系统 UI 仍显示旧图标，先判定为缓存问题；不要立即改回 TIFF/template 路线。

提交时应包含：

- `docs/assets/menu-icon-zh.svg`
- `Apps/LaplaceIME/LaplaceIME/MenuIconHans.pdf`
- `Apps/LaplaceIME/LaplaceIME/Info.plist`（仅当 icon key 有变化）
- `tools/make_menuicon_pdf.sh`（仅当生成流程有变化）
- 删除的旧图标资源（如果本次清理了废弃资源）

不要把临时预览 PNG、cache-bust 临时 PDF、旧 handoff 记录或无关本地化迁移混入图标修复提交。
