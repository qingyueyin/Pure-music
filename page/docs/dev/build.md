---
outline: deep
---

# 构建

## 环境

| 工具 | 说明 |
|------|------|
| Flutter | ≥ 3.16，Windows desktop 已启用 |
| Dart | ≥ 3.3 |
| Rust | 稳定工具链；`rust/rust-toolchain.toml` 如有锁定则跟随 |
| Visual Studio | 带 C++ 桌面开发工作负载 |
| flutter_rust_bridge_codegen | 改 Rust API 后需要 |

## 日常开发

```bash
flutter pub get
flutter run
```

Debug 构建：

```bash
flutter build windows --debug
```

## Release

```bash
flutter build windows --release
```

产物：`build/windows/x64/runner/Release/`

## 修改 Rust 之后

```bash
# 需已安装 codegen
flutter_rust_bridge_codegen generate
flutter pub get
flutter run
```

注意：`rust/Cargo.toml` 中 `flutter_rust_bridge` 版本需与工具链匹配（当前为 2.12.x 一带）。

## BASS 插件

Release 目录需要音频引擎相关 DLL（仓库 `BASS/`）。缺失时部分格式可能无法播放。

## 桌面歌词

桌面歌词是独立可执行进程，主程序通过服务与其通信。改相关功能时同时检查：

- `lib/play_service/desktop_lyric_service.dart`
- `packages/desktop_lyric/`
- `desktop_lyric/` 运行产物

## 常见构建问题

**Rust / FRB 编译失败**  
先确认 `cargo` 可用、toolchain 正确，再重新 `generate`。

**Windows 链接 / CMake 错误**  
确认 VS C++ 工作负载与 Flutter doctor 无阻塞项。

**能编译但不能播某些格式**  
检查 BASS 插件 DLL 是否随 Release 拷贝。

## 贡献前建议

1. 读 [架构](/dev/)
2. 涉及播放页动画 / 背景，遵守性能硬约束
3. 涉及歌词分组或音调，先确认是否属保护范围
