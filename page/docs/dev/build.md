---
outline: deep
---

# 构建

## 环境

| 工具 | 要求 |
|------|------|
| Flutter | ≥ 3.38.4，并启用 Windows desktop |
| Dart | 随 Flutter 安装，版本需 ≥ 3.10.3 |
| Rust | stable；仓库内 `rust/rust-toolchain.toml` 会选择工具链 |
| Visual Studio | 安装“使用 C++ 的桌面开发”，包含 Windows SDK 与 CMake 工具 |
| flutter_rust_bridge_codegen | 仅在修改 Rust 暴露 API 时需要，版本使用 2.12.0 |

先确认基础环境：

```powershell
flutter config --enable-windows-desktop
flutter doctor -v
cargo --version
```

`flutter doctor -v` 中 Windows toolchain 有阻塞项时，先补齐再继续。

## 首次运行

在仓库根目录执行：

```powershell
flutter pub get
flutter run -d windows
```

首次运行会同时编译 Flutter、Windows runner 与 Rust crate，通常比后续构建慢。BASS DLL 和桌面歌词运行文件由 CMake 从仓库目录复制，不需要手动放进 Debug 目录。

## 日常开发

| 改动 | 接下来做什么 |
|------|--------------|
| Dart / Flutter | 保存后热重载；涉及初始化时重新启动 |
| Rust 函数内部实现 | 停止应用后重新运行，Cargokit 会重新编译 Rust |
| `rust/src/api/` 的函数签名或类型 | 重新生成 FRB 绑定，再运行应用 |
| `pubspec.yaml` | 执行 `flutter pub get` |
| 文档站 | 进入 `page/` 运行文档开发服务器 |

Debug 构建：

```powershell
flutter build windows --debug
```

产物在 `build/windows/x64/runner/Debug/`。运行时要保留整个目录结构，不要只拿 `pure_music.exe`。

## 修改 Rust API

安装与项目匹配的 codegen：

```powershell
cargo install flutter_rust_bridge_codegen --version 2.12.0 --locked
flutter_rust_bridge_codegen generate
flutter pub get
flutter run -d windows
```

只有暴露函数的签名、参数或返回类型变化时才需要重新生成。`lib/native/rust/` 与 `rust/src/frb_generated.rs` 是生成文件，不要手动修改。

## Release 构建

普通 Release 构建：

```powershell
flutter build windows --release
```

产物在 `build/windows/x64/runner/Release/`。发布包必须保留 exe、根目录 DLL、`dll/` 与 `desktop_lyric/`。

根目录的 `build_windows.ps1` 用于正式发布打包：同步版本、清理旧构建、整理运行文件，并写入 `output/`。脚本先在临时目录组装并校验完整性，成功后再替换同版本旧产物，不会关闭正在运行的主程序。

交互菜单：

| 选项 | 作用 |
|------|------|
| 1 | 编译便携版（只出文件夹） |
| 2 | 编译便携版并打 zip |
| 3 | 编译并制作 Inno Setup 安装器 |
| 4 | 跳过编译，打包已有产物为便携 zip |
| 5 | 跳过编译，用已有产物制作安装器 |

非交互示例：

```powershell
# 便携 zip（Mode 2）
.\build_windows.ps1 -Version 2.3.0 -Mode 2 -NonInteractive

# 安装器（Mode 3，需本机已装 Inno Setup 6/7）
.\build_windows.ps1 -Version 2.3.0 -Mode 3 -NonInteractive
```

`PORTABLE_BUILD` 由脚本按产物类型注入：便携为 `true`（数据在 exe 旁 `data/`），安装版为 `false`（数据在 `%LOCALAPPDATA%\pure_music`）。

### 便携产物

- `output/pure_music_{ver}_release_portable/` 与可选 `.zip`
- 包内含 `upgrade_from_previous.ps1`、`PORTABLE_README.txt`
- zip 旁可有 SHA-256；包内有逐文件清单

`upgrade_from_previous.ps1` 只迁移旧便携版的曲库、设置和缓存，不会用旧版 `app.so` 或 Flutter 资源覆盖新版本。

### 安装器产物

- `output/pure_music_{ver}_release_installer.exe` 与 `.sha256`
- 脚本：`installer/pure_music.iss`；可选从便携版导入数据：`installer/import_portable_data.ps1`
- 默认安装到 `%LOCALAPPDATA%\Programs\Pure Music`，`PrivilegesRequired=lowest`（当前用户，无需管理员）

## 文档站

```powershell
cd page
npm ci
npm run dev
```

提交前可用 `npm run build` 检查静态站点，产物在 `page/docs/.vitepress/dist/`。

## 常见构建问题

**`flutter doctor` 提示缺少 Windows 工具链**  
在 Visual Studio Installer 中补装“使用 C++ 的桌面开发”、Windows SDK 与 CMake 工具。

**找不到 `cargo` 或 Rust 编译失败**  
确认 stable 工具链已安装，`cargo --version` 可执行，再删除失败的临时构建并重试。

**FRB 生成失败或生成后类型不一致**  
确认 Dart 依赖、Rust crate 与 codegen 都是 2.12.0，再从仓库根目录执行 `flutter_rust_bridge_codegen generate`。

**能编译，但播放或桌面歌词不可用**  
不要单独移动 exe；检查构建目录中的 `dll/BASS/` 与 `desktop_lyric/` 是否完整。

## 提交前

```powershell
flutter analyze
flutter test
```

按改动范围运行相关测试；涉及 Rust 时再执行 `cargo fmt --manifest-path rust/Cargo.toml -- --check`。播放页动画、歌词分组、音调或流光背景改动还需遵守 [架构页](/dev/) 中的保护与性能约束。
