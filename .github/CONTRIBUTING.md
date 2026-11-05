# 贡献指南

代码、文档或反馈都可以。

## 报告问题

- 先看 [常见问题](https://qingyueyin.github.io/Pure-music/guide/faq)
- 还不确定是不是程序问题，先到 [Discussions](https://github.com/qingyueyin/Pure-music/discussions/categories/general)
- 能复现的异常，用 [Issue 模板](https://github.com/qingyueyin/Pure-music/issues/new/choose)
- 「设置 → 关于 → 报告问题」会打开 Bug 表单并复制日志快照，粘贴到「完整日志」，不要用原始 `.log` 代替。读法见 [Issue 提交规范](https://github.com/qingyueyin/Pure-music/blob/main/.github/ISSUE_GUIDELINES.md)

安全漏洞不要发到 Issue 或 Discussions。见 [报告安全漏洞](https://github.com/qingyueyin/Pure-music/blob/main/.github/SECURITY.md)。

## 提交代码

1. Fork 后从 `main` 开功能分支
2. 按 [构建说明](https://qingyueyin.github.io/Pure-music/dev/build) 跑起来
3. `flutter analyze` 无错误，并跑相关测试
4. 说清改了什么、为什么改

## 约定

- 歌词分组、音调、流光律动等稳定功能，改前先问
- 不新加状态管理库
- 封面取色走 Rust k-means
- 不手改 `lib/native/rust/` 和 `rust/src/frb_generated.rs`

## 非代码

文档、错字、FAQ、翻译、Star 都欢迎。
