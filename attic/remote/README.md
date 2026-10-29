# 归档：远程曲库

2026-10-28 停用的远程曲库（Navidrome / WebDAV / SMB 来源的同步与播放）。功能没做完，先留代码不参与编译。

- `attic/**` 已在 `analysis_options.yaml` 里排除，不进分析也不进构建。
- 恢复步骤：`remote/*.dart` 搬回 `lib/remote/`，`page/` 下两个文件搬回 `lib/page/`。
- 用例一直留在 `test/remote/`（本地目录，不进仓库），`analysis_options.yaml` 里排除，恢复时把这条排除删掉。
- 同时要恢复：`lib/core/paths.dart` 的 `REMOTE_PAGE`、侧栏 `side_nav.dart` 入口、`entry.dart` 路由分支、`main.dart` 的 `RemoteLibrary.instance.init()`、播放/封面/详情/统计里的远程分支。
- Rust 侧删掉了 `build_remote_index_from_folders_recursively`，恢复后要重跑 `flutter_rust_bridge_codegen generate`，并补回 `library_db.dart`、`tag_reader.dart` 里被生成覆盖掉的 `export` 行。
- 用户已有的远程来源数据没有删，恢复后可以直接接着用。
