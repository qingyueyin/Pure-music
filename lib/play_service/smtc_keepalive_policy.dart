/// 周期心跳只推进度和播放状态。最小化也会走这条心跳，反复重刷会把封面和系统句柄越积越多。
bool smtcPeriodicKeepAliveRefreshesArtwork() => false;

/// 刚进入最小化或托盘时可以重刷一次，把系统媒体会话唤醒。
bool smtcKeepAliveRefreshesArtworkOnEnter() => true;
