# 参考项目 vs 当前项目的独占模式对比

## 快速对比表

| 方面 | coriander_player (✅ 完美) | Pure Music 修复前 (❌ 有问题) | Pure Music 修复后 (✅ 已修复) |
|------|:---:|:---:|:---:|
| **WASAPI 初始化** | | | |
| EXCLUSIVE flag | ✅ | ✅ | ✅ |
| EVENT flag | ✅ | ❌ **缺失** | ✅ |
| 缓冲配置 | 固定 0.05s | 可配置 | 固定 0.05s |
| 采样率 | 自动 (0) | 硬编码 44100 | 自动 (0) |
| 回调指针 | -1 | 0 | -1 |
| **流管理** | | | |
| _streamWasapiExclusive | 设置一致 | ❌ 不一致 | ✅ 已修复 |
| setSource 清理 | 正确 | ❌ 有遗漏 | ✅ 已修复 |
| 错误情况重置 | 完整 | ❌ 部分 | ✅ 已修复 |
| **模式切换** | | | |
| useExclusiveMode 逻辑 | 清晰 | ❌ 混乱 | ✅ 改进 |
| WASAPI 清理顺序 | 正确 | ❌ 顺序错 | ✅ 已修复 |
| BASS 重新初始化 | 有 | ❌ 可能缺失 | ✅ 已修复 |
| **播放控制** | | | |
| start() 实现 | 规范 | ✅ 已有 | ✅ 已有 |
| pause() 实现 | 规范 | ✅ 已有 | ✅ 已有 |
| Tempo/Pitch | 禁用 | ❌ 可能冲突 | ✅ 已禁用 |
| **错误处理** | | | |
| 初始化异常 | 详细 | ✅ | ✅ 增强 |
| WASAPI_Start 失败 | 完整处理 | ❌ 缺失处理 | ✅ 已增强 |
| 状态日志 | 详细 | ✅ | ✅ 保留 |

---

## 关键差异详解

### 1. BASS_WASAPI_EVENT 标志

**coriander_player:**
```dart
const flags = bass_wasapi.BASS_WASAPI_EXCLUSIVE | bass_wasapi.BASS_WASAPI_EVENT;
```

**Pure Music (修复前):**
```dart
final flags = bass_wasapi.BASS_WASAPI_EXCLUSIVE; // ❌ 缺少 EVENT
```

**Pure Music (修复后):**
```dart
const flags = bass_wasapi.BASS_WASAPI_EXCLUSIVE | bass_wasapi.BASS_WASAPI_EVENT; // ✅ 已添加
```

**影响：** 无此标志会导致 WASAPI 不能正确驱动音频播放，表现为卡顿或完全不工作。

---

### 2. 缓冲配置

**coriander_player:**
```dart
const bufferSec = 0.05; // 固定值，经验证稳定
```

**Pure Music (修复前):**
```dart
final bufferSec = pref.wasapiBufferSec.clamp(0.05, 0.30).toDouble();
// ❌ 用户可配置，不同值导致不稳定
```

**Pure Music (修复后):**
```dart
const bufferSec = 0.05; // ✅ 固定值
```

**影响：** 不同的缓冲值会导致初始化失败或播放延迟不一致。

---

### 3. 流状态标志管理

**coriander_player:**
```dart
void setSource(String path) {
  if (_fstream != null) {
    // 清理时总是重置
    _fstream = null;
    // ✅ 在此处重置流标志
  }
  // ... 创建新流 ...
  _fstream = handle;
  // ✅ 标记新流的模式
  _streamWasapiExclusive = wasapiExclusive;
}
```

**Pure Music (修复前):**
```dart
// ❌ 缺少重置
void setSource(String path) {
  if (_fstream != null) {
    _fstream = null;
    // 没有重置 _streamWasapiExclusive
  }
  _fstream = handle;
  _streamWasapiExclusive = wasapiExclusive;
}
```

**Pure Music (修复后):**
```dart
// ✅ 已修复
void setSource(String path) {
  if (_fstream != null) {
    _fstream = null;
    _streamWasapiExclusive = false; // 重置
  }
  _fstream = handle;
  _streamWasapiExclusive = wasapiExclusive; // 标记
}
```

**影响：** 未正确重置会导致模式切换时的状态混乱，可能导致使用错误的清理方式。

---

### 4. 模式切换清理顺序

**coriander_player:**
```dart
bool useExclusiveMode(bool exclusive) {
  if (_fstream != null) {
    if (_streamWasapiExclusive) {
      _bassWasapi.BASS_WASAPI_Free(); // 先清理 WASAPI
    }
    freeFStream(); // 再释放流
  }
  if (prevState) {
    _bassWasapi.BASS_WASAPI_Free();
    _bassInit(); // 重新初始化 BASS
  }
}
```

**Pure Music (修复前):**
```dart
// ❌ 顺序可能混乱，清理逻辑不完整
```

**Pure Music (修复后):**
```dart
// ✅ 明确的清理顺序和完整的处理
```

**影响：** 错误的清理顺序会导致资源泄漏或初始化失败。

---

### 5. 播放模式限制

**coriander_player:**
```dart
if (wasapiExclusive && !_isEqFlat) {
  logger.w("[bass] EQ enabled in exclusive mode, keep shared mode");
  useExclusiveMode(false);
  return;
}
// Tempo/Pitch 不应用
```

**Pure Music (修复前):**
```dart
// ❌ 可能尝试在独占模式下应用 Tempo/Pitch
if (_rate != 1.0) {
  setRate(_rate); // 可能失败
}
```

**Pure Music (修复后):**
```dart
// ✅ 仅在非独占模式下应用
if (_rate != 1.0 && !wasapiExclusive) {
  setRate(_rate);
}
if (_pitch != 0.0 && !wasapiExclusive) {
  setPitch(_pitch);
}
```

**影响：** 独占模式使用 DECODE 流，不支持 FX，尝试应用会导致失败。

---

## 修复验证清单

- [x] WASAPI EVENT flag 已添加
- [x] 缓冲配置已改为固定值
- [x] 采样率改为自动选择
- [x] _streamWasapiExclusive 状态管理已修复
- [x] setSource 清理逻辑已改进
- [x] useExclusiveMode 顺序已优化
- [x] Tempo/Pitch 限制已添加
- [x] 错误处理已增强
- [x] 代码分析无错误
- [x] 已提交 git

---

## 引用关系

```
参考项目
coriander_player
│
├─ 完美的独占模式实现
│  ├─ _bassWasapiInit() ✅
│  ├─ _startWasapiExclusive() ✅
│  ├─ _pauseWasapiExclusive() ✅
│  └─ useExclusiveMode() ✅
│
└─→ Pure Music (修复前)
    ├─ 缺少 EVENT flag ❌
    ├─ 配置不稳定 ❌
    ├─ 状态管理混乱 ❌
    └─ 限制不完整 ❌
    
    └─→ Pure Music (修复后)
        ├─ EVENT flag 已添加 ✅
        ├─ 配置已固定 ✅
        ├─ 状态已管理 ✅
        └─ 限制已实现 ✅
```

---

**修复日期**: 2026-03-12
**修复版本**: Pure Music + WASAPI Exclusive Mode Fix
**参考**: coriander_player (完美实现)
