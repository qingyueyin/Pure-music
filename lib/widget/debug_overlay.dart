import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pure_music/core/performance_monitor.dart';

class DebugOverlay extends StatefulWidget {
  final Widget child;
  final bool initiallyVisible;

  const DebugOverlay({
    super.key,
    required this.child,
    this.initiallyVisible = false,
  });

  @override
  State<DebugOverlay> createState() => _DebugOverlayState();
}

class _DebugOverlayState extends State<DebugOverlay> {
  bool _isVisible = false;
  PerformanceStats? _lastStats;
  bool _showFps = true;

  @override
  void initState() {
    super.initState();
    _isVisible = widget.initiallyVisible && kDebugMode;

    if (_isVisible) {
      _startMonitoring();
    }
  }

  void _startMonitoring() {
    PerformanceMonitor().startMonitoring();
    PerformanceMonitor().onStatsUpdate = (stats) {
      if (mounted) {
        setState(() {
          _lastStats = stats;
        });
      }
    };
  }

  void _toggleOverlay() {
    setState(() {
      _isVisible = !_isVisible;
      if (_isVisible) {
        _startMonitoring();
      } else {
        PerformanceMonitor().stopMonitoring();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode) {
      return widget.child;
    }

    return Stack(
      children: [
        widget.child,
        if (_isVisible) _buildOverlay(),
        _buildFloatingButton(),
      ],
    );
  }

  Widget _buildOverlay() {
    return Positioned(
      top: 40,
      right: 20,
      child: Material(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 200,
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '调试信息',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold),
              ),
              const Divider(color: Colors.white30),
              if (_showFps && _lastStats != null) ...[
                _buildInfoRow('FPS', '${_lastStats!.fps.toStringAsFixed(1)}'),
                _buildInfoRow('丢帧', '${_lastStats!.droppedFrames}'),
                _buildInfoRow(
                    '帧时间', '${_lastStats!.avgFrameTime.toStringAsFixed(1)}ms'),
                _buildStatusRow(
                    '流畅度',
                    _lastStats!.isSmooth
                        ? '流畅'
                        : (_lastStats!.isAcceptable ? '一般' : '卡顿'),
                    color: _lastStats!.isSmooth
                        ? Colors.green
                        : (_lastStats!.isAcceptable ? Colors.orange : Colors.red)),
              ],
              const SizedBox(height: 8),
              const Divider(color: Colors.white30),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('显示FPS',
                      style: TextStyle(color: Colors.white, fontSize: 12)),
                  Switch(
                    value: _showFps,
                    onChanged: (v) => setState(() => _showFps = v),
                    activeColor: Colors.blue,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => PerformanceMonitor.triggerGC(),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                      child: const Text('手动GC',
                          style: TextStyle(fontSize: 12, color: Colors.white)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
          Text(value,
              style: const TextStyle(color: Colors.white, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildStatusRow(String label, String status,
      {Color color = Colors.white}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: color.withValues(alpha: 0.5)),
            ),
            child: Text(status,
                style: TextStyle(color: color, fontSize: 10)),
          ),
        ],
      ),
    );
  }

  Widget _buildFloatingButton() {
    return Positioned(
      top: 40,
      right: 20,
      child: GestureDetector(
        onTap: _toggleOverlay,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: _isVisible ? Colors.blue : Colors.black54,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white30),
          ),
          child: Icon(
            _isVisible ? Icons.bug_report : Icons.bug_report_outlined,
            color: Colors.white,
            size: 20,
          ),
        ),
      ),
    );
  }
}
