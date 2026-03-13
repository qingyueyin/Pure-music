# WASAPI 独占模式修复说明

## 概述

通过分析和应用参考项目 `coriander_player` 的完美实现，修复了 Pure Music 的 WASAPI 独占模式问题。修复包括 5 个关键领域的改进。

---

## 问题分析

### 原始实现的缺陷

1. **WASAPI 初始化配置不完整**
   - 缺少 `BASS_WASAPI_EVENT` 标志（关键）
   - 使用可配置的缓冲时间，导致不稳定
   - 采样率硬编码为 44100，不让 WASAPI 自动选择

2. **流状态管理混乱**
   - `_streamWasapiExclusive` 标志管理不当
   - 流模式切换时清理逻辑不正确
   - 独占模式与普通模式混用导致冲突

3. **播放状态判断有问题**
   - 独占模式下无法正确判断暂停状态
   - 状态转换时没有正确的回调机制

4. **资源释放不彻底**
   - WASAPI 清理顺序不对
   - 流标志重置不完整

---

## 修复方案详解

### 1️⃣ WASAPI 初始化配置（_bassWasapiInit）

**问题代码：**
```dart
final pref = AppPreference.instance.playbackPref;
final bufferSec = pref.wasapiBufferSec.clamp(0.05, 0.30).toDouble();
final flags = bass_wasapi.BASS_WASAPI_EXCLUSIVE;
const initFreq = 44100;
```

**修复代码：**
```dart
// 使用参考项目的标准配置
const flags = bass_wasapi.BASS_WASAPI_EXCLUSIVE | bass_wasapi.BASS_WASAPI_EVENT;
const bufferSec = 0.05; // 固定 50ms 缓冲，经过验证的稳定值
const initFreq = 0; // 让 WASAPI 自动选择合适的采样率
```

**关键改变：**
- ✅ 添加 `BASS_WASAPI_EVENT` flag - 启用事件驱动的缓冲
- ✅ 固定缓冲为 0.05 秒 - 经过验证的稳定值
- ✅ 采样率改为 0 - 让 WASAPI 自动选择设备的合适采样率
- ✅ 回调指针改为 -1 - 表示无自定义回调函数

**为什么这很重要：**
- `BASS_WASAPI_EVENT` 是事件驱动式音频处理的关键，无此flag会导致播放不稳定
- 固定的缓冲值避免了用户配置导致的初始化失败
- 让 WASAPI 自动选择采样率可以适应不同的音频设备

---

### 2️⃣ 流状态标志管理（setSource）

**问题：** `_streamWasapiExclusive` 标志在多个地方没有正确设置和重置

**修复：**
```dart
void setSource(String path) {
  if (_fstream != null) {
    // ... 清理旧流 ...
    _fstream = null;
    _streamWasapiExclusive = false; // 重置流的状态标志 ← 新增
  }
  
  // ... 创建新流 ...
  
  if (handle != 0) {
    _fstream = handle;
    _fPath = path;
    // 标记当前流是否为独占模式流 ← 关键
    _streamWasapiExclusive = wasapiExclusive;
  } else {
    _fstream = null;
    _fPath = null;
    _streamWasapiExclusive = false; // 错误情况下也要重置
  }
}
```

**为什么这很重要：**
- 准确的流模式标记确保了切换模式时的正确清理
- 防止了共享模式和独占模式混用时的状态混乱

---

### 3️⃣ 模式切换逻辑（useExclusiveMode）

**改进点：**
```dart
bool useExclusiveMode(bool exclusive) {
  final prevState = wasapiExclusive;
  try {
    // ... 参数检查 ...
    if (_fstream != null) {
      if (_streamWasapiExclusive) {
        // 之前是独占模式，需要清理 WASAPI ← 明确注释
        _bassWasapi.BASS_WASAPI_Stop(bass.TRUE);
        _bassWasapi.BASS_WASAPI_Free();
      } else {
        // 之前是共享模式，停止通常的播放 ← 明确注释
        _bass.BASS_ChannelStop(_fstream!);
      }
    }
    if (prevState) {
      // 从独占模式切换出来，需要清理 WASAPI 并重新初始化 BASS ← 明确注释
      _bassWasapi.BASS_WASAPI_Stop(bass.TRUE);
      _bassWasapi.BASS_WASAPI_Free();
      _bassInit();
    }
    wasapiExclusive = exclusive;
    onExclusiveModeChanged?.call(exclusive);
    // 重新加载歌曲...
  }
}
```

**为什么这很重要：**
- 清晰的清理顺序防止了资源泄漏
- 正确处理两种模式之间的转换

---

### 4️⃣ 播放模式限制

**新增限制：** 独占模式下禁用 Tempo/Pitch
```dart
if (handle != 0) {
  _fstream = handle;
  _fPath = path;
  _streamWasapiExclusive = wasapiExclusive;
  
  // 仅在非独占模式下应用 Tempo/Pitch
  if (_rate != 1.0 && !wasapiExclusive) {
    setRate(_rate);
  }
  if (_pitch != 0.0 && !wasapiExclusive) {
    setPitch(_pitch);
  }
}
```

**为什么这很重要：**
- 独占模式使用 DECODE 流，不支持 FX 效果
- 防止了播放异常或初始化失败

---

### 5️⃣ 错误处理增强

**改进示例：**
```dart
void _startWasapiExclusive() {
  if (_bassWasapi.BASS_WASAPI_Start() == bass.FALSE) {
    final errorCode = _bass.BASS_ErrorGetCode();
    logger.e("[bass] BASS_WASAPI_Start failed: $errorCode");
    switch (errorCode) {
      // ...
      default:
        throw FormatException("WASAPI Start failed with error: $errorCode");
    }
  }
}
```

---

## 技术背景

### WASAPI 独占模式的工作原理

```
普通模式（共享）：
App → BASS_Channel → Windows Audio Engine → 硬件

独占模式：
App → BASS_DECODE_Channel → WASAPI → 硬件
        (独占使用设备)
```

独占模式的特点：
- ✅ 更低的延迟（绕过 Windows 混音器）
- ✅ 更高的音质（直接控制设备采样率）
- ✅ 独占使用音频设备
- ❌ 无法与其他应用共享音频输出
- ❌ 不支持实时效果（EQ、Tempo、Pitch）

### BASS_WASAPI_EVENT 标志的作用

`BASS_WASAPI_EVENT` 标志启用了事件驱动式音频处理：
- 当 WASAPI 需要音频数据时，会发送事件通知
- BASS 库负责按需解码和提交数据
- 这是现代音频系统的标准做法
- 无此标志会导致严重的播放问题

---

## 验证方法

测试步骤：

1. **启用独占模式**
   ```
   1. 打开应用
   2. 点击播放页面的"Excl"按钮
   3. 应该切换到独占模式无错误
   ```

2. **播放音乐**
   ```
   1. 切换到独占模式
   2. 播放任意音乐
   3. 应该正常播放
   ```

3. **暂停和恢复**
   ```
   1. 在独占模式下播放音乐
   2. 点击暂停
   3. 应该正常暂停
   4. 点击播放
   5. 应该恢复播放
   ```

4. **模式切换**
   ```
   1. 在独占模式播放音乐
   2. 点击"Excl"切回共享模式
   3. 应该无缝切换，音乐继续播放
   ```

---

## 参考资源

- **参考项目**：D:\All\Documents\Projects\player\Pure-music\.trae\good\coriander_player
- **BASS 文档**：http://www.un4seen.com
- **WASAPI 规范**：Microsoft Windows Audio Session API

---

## 提交信息

```
fix(audio): 修复 WASAPI 独占模式实现

应用 coriander_player 的参考实现来修复独占模式的多个问题。

关键修复：
1. WASAPI 初始化配置（添加 EVENT flag，固定缓冲，自动采样率）
2. 流状态管理（正确设置和重置 _streamWasapiExclusive）
3. 模式切换逻辑（改进清理顺序和状态处理）
4. 播放模式限制（独占模式下禁用 Tempo/Pitch）
5. 错误处理增强（更详细的日志和异常信息）
```

---

**修复日期**：2026-03-12
**修复者**：OpenCode
**审核参考**：coriander_player (音乐播放器完美实现)
