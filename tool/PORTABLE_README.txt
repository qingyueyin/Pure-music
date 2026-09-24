Pure Music Windows 便携版

首次使用
1. 完整解压 ZIP，不要只复制 pure_music.exe。
2. 进入解压目录，运行 pure_music.exe。
3. 曲库、设置和缓存会保存在解压目录\data 中，移动整个解压目录即可带走数据。

从旧便携版升级
1. 应用内更新会自动解压新版、迁移数据并重启；旧目录会保留为备份。
2. 如果应用内更新不可用，把新版完整解压到新的空目录，不要覆盖旧目录。
3. 关闭新旧两个目录中的 Pure Music。
4. 运行新版包根目录的 .update\upgrade_from_previous.ps1，选择旧版包目录。
5. 迁移完成后运行新版解压目录\pure_music.exe，确认曲库和设置正常，再保留或删除旧目录。

完整性校验
- ZIP 旁的 .sha256 文件用于校验下载文件。
- .update\package_manifest.json 和 .update\SHA256SUMS.txt 用于校验解压后的文件。
