# Linguist Zixia Input | 紫霞输入法

## Build & Test

- 测试：`swift test --package-path Packages/PinyinEngine`（引擎代码修改后必须执行）
- 格式化：`make format`（Swift / Markdown 修改后必须执行，须在 commit 前完成）

## Conventions

- 中文标点使用「」而非 ""，代码注释使用中文
- 中文表达（注释、文档、commit message、对话）必须使用严谨的书面语，不得出现口语化表达、网络用语、语气词（"吧/呗/嘛/哈"等）。本项目为语言学产品，所有中文表达须经得起语言学审视，会话与书面文档采用相同的学术写作标准。
- 禁用中国互联网公司黑话（如「赋能」「抓手」「闭环」「落地」「落入文件」等比喻性套话），这类表达将不精确的管理学概念伪装成确定性术语，与语言学产品的精度要求相悖。
