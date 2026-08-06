Pure Music Windows 便携版

首次使用
1. 完整解压 ZIP，不要只复制 pure_music.exe。
2. 进入 app 目录，运行 pure_music.exe。
3. 曲库、设置和缓存会保存在 app\data 中，移动整个 app 目录即可带走数据。

从旧便携版升级
1. 把新版完整解压到新的空目录，不要覆盖旧目录。
2. 关闭新旧两个目录中的 Pure Music。
3. 运行新版包根目录的 upgrade_from_previous.ps1，选择旧版包目录。
4. 迁移完成后运行新版 app\pure_music.exe，确认曲库和设置正常，再保留或删除旧目录。

完整性校验
- ZIP 旁的 .sha256 文件用于校验下载文件。
- package_manifest.json 和 SHA256SUMS.txt 用于校验解压后的文件。
