---
outline: deep
---

# 贡献指南

欢迎为 Pure Music 贡献代码、文档或反馈。

## 报告问题

- 设置中的「报告问题」可以生成并复制日志，需要手动粘贴到 Issue 正文
- 也可在 [GitHub Issues](https://github.com/qingyueyin/Pure-music/issues) 提交
- 附上复现步骤、系统版本与日志，能帮助更快定位

## 提交代码

1. Fork 并 clone 仓库
2. 功能分支从 main 分出来
3. 按 [构建指南](/dev/build) 完成首次运行
4. 确保 `flutter analyze` 无错误，并运行与改动相关的测试
5. 描述清楚改了什么、为什么改

开发环境搭建见 [构建](/dev/build)。

## 代码约定

项目遵循仓库根目录 `AGENTS.md` 与 `CLAUDE.md` 中的规范，主要原则：

- 不改播放页语言分组与音调等高稳定功能前先问
- 不引入不在依赖列表中的状态管理库
- 新增封面取色路径使用 Rust k-means，不再扩展 `PaletteGenerator` 的使用范围
- 颜色用 `Color.withValues(alpha:)`，不用 `withOpacity`
- 不手动修改 `lib/native/rust/` 与 `rust/src/frb_generated.rs` 中的生成代码

## 非代码贡献

- 完善文档、修正错别字、补充 FAQ
- 翻译（页面 / 应用内文案）
- 推广 —— 在社交平台分享、加 Star

## 行为准则

保持开放和尊重。讨论聚焦于代码和产品，不欢迎人身攻击。
