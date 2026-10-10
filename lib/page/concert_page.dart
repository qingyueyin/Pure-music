import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/audio_tile.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/stacked_list_view.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/core/mouse_back_exit.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/playlist.dart';
import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/services/concert_program_store.dart';
import 'package:pure_music/services/concert_session.dart';
import 'package:pure_music/services/smart_sort_service.dart';
import 'package:pure_music/services/smart_sort_options.dart';

/// 演出模式：圈定素材 → 生成演唱会式编排顺序 → 替换当前队列开演。
/// 编排顺序由算法所有，页内不提供手动排序；原歌单不做任何修改。
class ConcertPage extends StatefulWidget {
  const ConcertPage({super.key});

  @override
  State<ConcertPage> createState() => _ConcertPageState();
}

enum _ConcertPhase { select, analyzing, result }

enum _SourceKind {
  folders('文件夹', Symbols.folder),
  artists('歌手', Symbols.artist),
  albums('专辑', Symbols.album),
  playlists('歌单', Symbols.list);

  const _SourceKind(this.label, this.icon);
  final String label;
  final IconData icon;
}

class _ConcertPageState extends State<ConcertPage> {
  static const double _audioRowExtent = 64;
  static const double _footerRowExtent = 48;

  _ConcertPhase _phase = _ConcertPhase.select;
  _SourceKind _sourceKind = _SourceKind.folders;
  bool _entireLibrary = false;
  final selectedFolders = <String>{};
  final selectedArtists = <String>{};
  final selectedAlbums = <String>{};
  final selectedPlaylists = <String>{};
  double _climaxPosition = 0.82;
  double _contrast = 0.85;
  int _setSize = 0;
  double _smoothness = 0.5;
  int _outroStyle = 0;
  int _taste = 0;
  int _analyzedCount = 0;
  int _totalCount = 0;
  bool _stopRequested = false;
  int _generation = 0;
  bool _replanning = false;
  bool _adjusterOpen = false;
  int _highlightIndex = -1;
  Timer? _highlightTimer;
  String? _activeProgramId;
  List<ConcertProgram> _programs = [];
  final _resultListController = SmoothScrollController();
  final _sourceListController = SmoothScrollController();
  SmartSortResult? _result;

  @override
  void initState() {
    super.initState();
    MouseBackExit.registerRoute(app_paths.CONCERT_PAGE, _handleNavigationReset);
    ConcertSession.instance.addListener(_onSessionChanged);
    ConcertProgramStore.instance.load().then((_) {
      if (!mounted) return;
      setState(() {
        _programs = List.of(ConcertProgramStore.instance.programs);
      });
    });
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    MouseBackExit.unregisterRoute(
      app_paths.CONCERT_PAGE,
      _handleNavigationReset,
    );
    ConcertSession.instance.removeListener(_onSessionChanged);
    _stopRequested = true;
    _generation++;
    _highlightTimer?.cancel();
    _resultListController.dispose();
    _sourceListController.dispose();
    super.dispose();
  }

  bool _handleNavigationReset() {
    if (!mounted) return false;
    if (_phase == _ConcertPhase.analyzing) {
      _requestStop();
      return true;
    }
    if (_phase != _ConcertPhase.result) return false;
    setState(() {
      _phase = _ConcertPhase.select;
      _adjusterOpen = false;
      _highlightIndex = -1;
    });
    return true;
  }

  List<Audio> _collectSelectedAudios() {
    if (_entireLibrary) {
      return List.of(AudioLibrary.instance.audioCollection);
    }
    final collected = <String, Audio>{};
    void absorb(Iterable<Audio> audios) {
      for (final audio in audios) {
        collected.putIfAbsent(audio.path, () => audio);
      }
    }

    for (final folder in AudioLibrary.instance.folders) {
      if (selectedFolders.contains(folder.path)) absorb(folder.audios);
    }
    for (final artist in AudioLibrary.instance.artistCollection.values) {
      if (selectedArtists.contains(artist.name)) absorb(artist.works);
    }
    for (final album in AudioLibrary.instance.albumCollection.values) {
      if (selectedAlbums.contains(album.name)) absorb(album.works);
    }
    for (final playlist in playlists) {
      if (selectedPlaylists.contains(playlist.name)) absorb(playlist.audios);
    }
    return collected.values.toList();
  }

  bool get _hasSelection =>
      _entireLibrary ||
      selectedFolders.isNotEmpty ||
      selectedArtists.isNotEmpty ||
      selectedAlbums.isNotEmpty ||
      selectedPlaylists.isNotEmpty;

  int _kindSelectionCount(_SourceKind kind) => switch (kind) {
    _SourceKind.folders => selectedFolders.length,
    _SourceKind.artists => selectedArtists.length,
    _SourceKind.albums => selectedAlbums.length,
    _SourceKind.playlists => selectedPlaylists.length,
  };

  void _clearSelection() {
    _entireLibrary = false;
    selectedFolders.clear();
    selectedArtists.clear();
    selectedAlbums.clear();
    selectedPlaylists.clear();
    setState(() {});
  }

  /// 素材来源的展示名：取前两个来源名，更多以"等"收尾。
  String _selectionName() {
    if (_entireLibrary) return '整个曲库';
    final names = <String>[
      for (final folder in AudioLibrary.instance.folders)
        if (selectedFolders.contains(folder.path)) folder.displayName,
      for (final artist in AudioLibrary.instance.artistCollection.values)
        if (selectedArtists.contains(artist.name)) artist.name,
      for (final album in AudioLibrary.instance.albumCollection.values)
        if (selectedAlbums.contains(album.name)) album.name,
      for (final playlist in playlists)
        if (selectedPlaylists.contains(playlist.name)) playlist.name,
    ];
    if (names.isEmpty) return '自选曲目';
    final shown = names.take(2).join(' · ');
    return names.length > 2 ? '$shown 等' : shown;
  }

  Future<void> _generatePlan() async {
    final tracks = _collectSelectedAudios();
    if (tracks.length < 2) {
      showTextOnSnackBar('至少选择两首乐曲', variant: ToastVariant.error);
      return;
    }
    await _runGeneration(
      tracks,
      name: _selectionName(),
      existingId: null,
      showProgress: true,
    );
  }

  /// 分析 + 编排 + 存档。缓存命中时近乎瞬时；showProgress 决定是否切到进度页。
  Future<void> _runGeneration(
    List<Audio> tracks, {
    required String name,
    required String? existingId,
    required bool showProgress,
    int? takeCount,
  }) async {
    if (tracks.length < 2) {
      showTextOnSnackBar('节目里的乐曲已不在曲库中', variant: ToastVariant.error);
      return;
    }
    final generation = ++_generation;
    _markGenerationStarted(showProgress: showProgress, total: tracks.length);
    try {
      final result = await SmartSortService.run(
        _sortOptions(tracks, generation, takeCount),
      );
      if (!mounted || generation != _generation) return;
      await _persistGeneratedProgram(
        tracks: tracks,
        result: result,
        name: name,
        existingId: existingId,
      );
      _showGenerationResult(result);
    } on SmartSortCancelledException {
      _abortGeneration(generation);
    } catch (error, trace) {
      log.library.error(
        'legacy',
        '[smart sort] plan failed',
        error: error,
        stackTrace: trace,
      );
      _abortGeneration(generation, notify: true);
    }
  }

  SmartSortOptions _sortOptions(
    List<Audio> tracks,
    int generation,
    int? takeCount,
  ) {
    return SmartSortOptions(
      tracks: tracks,
      climaxPosition: _climaxPosition,
      contrast: _contrast,
      takeCount: takeCount ?? _setSize,
      smoothness: _smoothness,
      outroStyle: _outroStyle,
      taste: _taste,
      onProgress: (done, _) {
        if (mounted && generation == _generation) {
          setState(() => _analyzedCount = done);
        }
      },
      isCancelled: () => _stopRequested || generation != _generation,
    );
  }

  void _markGenerationStarted({
    required bool showProgress,
    required int total,
  }) {
    if (!mounted) return;
    if (showProgress) {
      setState(() {
        _phase = _ConcertPhase.analyzing;
        _stopRequested = false;
        _analyzedCount = 0;
        _totalCount = total;
      });
      return;
    }
    setState(() => _replanning = true);
  }

  Future<void> _persistGeneratedProgram({
    required List<Audio> tracks,
    required SmartSortResult result,
    required String name,
    required String? existingId,
  }) async {
    _activeProgramId =
        existingId ?? DateTime.now().microsecondsSinceEpoch.toString();
    final store = ConcertProgramStore.instance;
    final existing = store.programs.where(
      (program) => program.id == _activeProgramId,
    );
    await store.upsert(
      ConcertProgram(
        id: _activeProgramId!,
        name: existing.isNotEmpty ? existing.first.name : name,
        createdAt: DateTime.now(),
        climaxPosition: _climaxPosition,
        contrast: _contrast,
        setSize: _setSize,
        smoothness: _smoothness,
        outroStyle: _outroStyle,
        taste: _taste,
        sourcePaths: [for (final audio in tracks) audio.path],
        paths: [for (final audio in result.audios) audio.path],
        idealCurve: result.idealCurve,
        actualCurve: result.actualCurve,
      ),
    );
    _programs = List.of(store.programs);
  }

  void _showGenerationResult(SmartSortResult result) {
    setState(() {
      _result = result;
      _replanning = false;
      _phase = _ConcertPhase.result;
      _highlightIndex = -1;
    });
  }

  void _abortGeneration(int generation, {bool notify = false}) {
    if (!mounted || generation != _generation) return;
    setState(() => _phase = _ConcertPhase.select);
    if (notify) {
      showTextOnSnackBar('生成编排失败', variant: ToastVariant.error);
    }
  }

  /// 结果页调整参数后的静默重排：特征已全量缓存，通常毫秒级完成。
  Future<void> _replanQuietly() async {
    final result = _result;
    if (result == null || _replanning) return;
    await _runGeneration(
      result.audios,
      name: _selectionName(),
      existingId: _activeProgramId,
      showProgress: false,
    );
  }

  /// 从历史存档恢复：参数与曲目原样带回，特征走缓存即时出结果。
  String _pathKey(String path) =>
      path.trim().replaceAll('\\', '/').toLowerCase();

  Map<String, Audio> _audioByPath() {
    return {
      for (final audio in AudioLibrary.instance.audioCollection)
        _pathKey(audio.path): audio,
    };
  }

  List<Audio> _tracksFromPaths(List<String> paths, Map<String, Audio> byPath) {
    return [
      for (final path in paths)
        if (byPath[_pathKey(path)] != null) byPath[_pathKey(path)]!,
    ];
  }

  void _applyProgramKnobs(ConcertProgram program) {
    _climaxPosition = program.climaxPosition;
    _contrast = program.contrast;
    _setSize = program.setSize;
    _smoothness = program.smoothness;
    _outroStyle = program.outroStyle;
    _taste = program.taste;
  }

  bool _hasCompleteCurve(ConcertProgram program, List<Audio> orderedTracks) {
    return program.idealCurve.length == orderedTracks.length &&
        program.actualCurve.length == orderedTracks.length &&
        program.idealCurve.every((value) => value.isFinite) &&
        program.actualCurve.every((value) => value.isFinite);
  }

  void _showRestoredResult(ConcertProgram program, List<Audio> orderedTracks) {
    _activeProgramId = program.id;
    setState(() {
      _result = SmartSortResult(
        audios: orderedTracks,
        idealCurve: List.of(program.idealCurve),
        actualCurve: List.of(program.actualCurve),
        analyzedCount: 0,
        cachedCount: orderedTracks.length,
      );
      _replanning = false;
      _phase = _ConcertPhase.result;
      _highlightIndex = -1;
    });
  }

  Future<void> _restoreProgram(ConcertProgram program) async {
    final byPath = _audioByPath();
    final sourcePaths = program.sourcePaths.isEmpty
        ? [
            for (final audio in AudioLibrary.instance.audioCollection)
              audio.path,
          ]
        : program.sourcePaths;
    final sourceTracks = _tracksFromPaths(sourcePaths, byPath);
    final orderedTracks = _tracksFromPaths(program.paths, byPath);
    _applyProgramKnobs(program);
    if (orderedTracks.isNotEmpty &&
        orderedTracks.length == program.paths.length &&
        _hasCompleteCurve(program, orderedTracks)) {
      _showRestoredResult(program, orderedTracks);
      return;
    }
    await _runGeneration(
      sourceTracks,
      name: program.name,
      existingId: program.id,
      showProgress: true,
      takeCount: program.setSize,
    );
  }

  Future<void> _showSettingsDialog() async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return StatefulBuilder(
          builder: (context, dialogSetState) => AlertDialog(
            title: const Text('演出设置'),
            content: SingleChildScrollView(
              child: _buildAdvancedCard(scheme, dialogSetState: dialogSetState),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('完成'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showEmotionCurveDialog() async {
    final result = _result;
    if (result == null) return;
    var highlightIndex = -1;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, dialogSetState) => AlertDialog(
          title: const Text('情绪曲线'),
          content: SizedBox(
            width: 640,
            height: 220,
            child: _emotionCurveBody(result, highlightIndex, (local, size) {
              final ratio = (local.dx / size.width).clamp(0.0, 1.0);
              highlightIndex = (ratio * (result.audios.length - 1)).round();
              dialogSetState(() {});
              _locateFromChart(local, size);
            }),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('完成'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emotionCurveBody(
    SmartSortResult result,
    int highlightIndex,
    void Function(Offset local, Size size) onTap,
  ) {
    if (result.actualCurve.length < 2) {
      return const Center(child: Text('当前演出没有可显示的情绪曲线'));
    }
    return _tappableCurve(
      idealCurve: result.idealCurve,
      actualCurve: result.actualCurve,
      highlightIndex: highlightIndex,
      onTap: onTap,
    );
  }

  Widget _tappableCurve({
    required List<double> idealCurve,
    required List<double> actualCurve,
    required int highlightIndex,
    required void Function(Offset local, Size size) onTap,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) => onTap(details.localPosition, constraints.biggest),
        child: _CurveChart(
          idealCurve: idealCurve,
          actualCurve: actualCurve,
          highlightIndex: highlightIndex,
        ),
      ),
    );
  }

  Future<void> _deleteProgram(String id) async {
    await ConcertProgramStore.instance.remove(id);
    if (_activeProgramId == id) _activeProgramId = null;
    setState(() {
      _programs = List.of(ConcertProgramStore.instance.programs);
    });
  }

  void _requestStop() {
    _stopRequested = true;
    _generation++;
    if (mounted) {
      setState(() => _phase = _ConcertPhase.select);
    }
  }

  String _currentShowName() {
    final id = _activeProgramId;
    if (id != null) {
      for (final program in _programs) {
        if (program.id == id) return program.name;
      }
    }
    return _selectionName();
  }

  Future<void> _restoreAndStart(ConcertProgram program) async {
    await _restoreProgram(program);
    if (!mounted) return;
    if (_phase != _ConcertPhase.result) return;
    await _startShow();
  }

  Future<void> _startShow() async {
    final result = _result;
    if (result == null || result.audios.isEmpty) return;
    final playbackService = PlayService.instance.playbackService;
    // 编排顺序表达叙事意图，开演前退出随机模式避免队列被打乱。
    if (playbackService.shuffle.value) {
      playbackService.useShuffle(false);
    }
    playbackService.play(0, result.audios);
    ConcertSession.instance.begin(
      name: _currentShowName(),
      paths: [for (final audio in result.audios) audio.path],
      climaxPosition: _climaxPosition,
    );
    final act = ConcertSession.instance.actAt(0) ?? '演出';
    showTextOnSnackBar('$act开始 · 今晚 ${result.audios.length} 首');
    context.push(app_paths.NOW_PLAYING_PAGE);
  }

  Future<void> _saveResultAsPlaylist() async {
    final result = _result;
    if (result == null || result.audios.isEmpty) return;
    final savedName = await _offerSaveAsPlaylist(result.audios);
    if (!mounted || savedName == null) return;
    showTextOnSnackBar('已存为歌单「$savedName」', variant: ToastVariant.success);
  }

  Future<String?> _offerSaveAsPlaylist(List<Audio> audios) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _SaveConcertPlaylistDialog(
        initialName: _currentShowName(),
        existingNames: {for (final playlist in playlists) playlist.name},
      ),
    );
    if (!mounted || name == null || name.isEmpty) return null;
    return _saveConcertPlaylist(name, audios);
  }

  Future<String?> _saveConcertPlaylist(String name, List<Audio> audios) async {
    try {
      final playlist = await createPlaylist(name);
      for (final audio in audios) {
        playlist.addPath(audio.path);
      }
      playlists.add(playlist);
      final saved = await savePlaylists();
      if (!saved) {
        showTextOnSnackBar('保存歌单失败', variant: ToastVariant.error);
        return null;
      }
      return playlist.name;
    } on PlaylistAlreadyExistsException {
      showTextOnSnackBar('该名称已存在', variant: ToastVariant.error);
      return null;
    } catch (error, trace) {
      log.library.error('legacy', '演出存为歌单失败', error: error, stackTrace: trace);
      showTextOnSnackBar('保存歌单失败', variant: ToastVariant.error);
      return null;
    }
  }

  /// 点击曲线图上的点，列表按比例滚动到对应曲目并短暂高亮。
  void _locateFromChart(Offset localPosition, Size chartSize) {
    final result = _result;
    if (result == null || result.audios.isEmpty) return;
    if (!_resultListController.hasClients) return;
    final count = result.audios.length;
    final ratio = (localPosition.dx / chartSize.width).clamp(0.0, 1.0);
    final index = (ratio * (count - 1)).round();
    _flashHighlight(index);
    final maxExtent = _resultListController.position.maxScrollExtent;
    _resultListController.animateTo(
      ratio * maxExtent,
      duration: MotionDuration.base,
      curve: MotionCurve.standard,
    );
  }

  void _flashHighlight(int index) {
    _highlightTimer?.cancel();
    setState(() => _highlightIndex = index);
    _highlightTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _highlightIndex = -1);
    });
  }

  String get _subtitle => switch (_phase) {
    _ConcertPhase.select =>
      _programs.isEmpty ? '圈定素材，一键编排成演唱会式的播放顺序' : '点开一场最近的演出直接开演，或圈定新素材',
    _ConcertPhase.analyzing =>
      '正在分析乐曲特征 $_analyzedCount / $_totalCount（已分析的曲目自动走缓存）',
    _ConcertPhase.result when _replanning => '正在按新参数重新编排…',
    _ConcertPhase.result =>
      _result == null
          ? '编排完成'
          : '编排完成 ${_result!.audios.length} 首（新分析 ${_result!.analyzedCount}，缓存 ${_result!.cachedCount}）',
  };

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: '演出模式',
      subtitle: _subtitle,
      actions: _phaseActions(),
      body: ListenableBuilder(
        listenable: AppSettings.listMotionNotifier,
        builder: (context, _) => switch (_phase) {
          _ConcertPhase.select => _buildSelectBody(context),
          _ConcertPhase.analyzing => _buildAnalyzingBody(context),
          _ConcertPhase.result => _buildResultBody(context),
        },
      ),
    );
  }

  List<Widget> _phaseActions() {
    final actions = switch (_phase) {
      _ConcertPhase.select => [
        OutlinedButton.icon(
          onPressed: _showSettingsDialog,
          icon: const Icon(Symbols.tune),
          label: const Text('演出设置'),
        ),
        FilledButton.icon(
          onPressed: _hasSelection ? _generatePlan : null,
          icon: const Icon(Symbols.auto_awesome),
          label: const Text('生成编排'),
        ),
      ],
      _ConcertPhase.analyzing => [
        OutlinedButton.icon(
          onPressed: _requestStop,
          icon: const Icon(Symbols.stop),
          label: const Text('停止'),
        ),
      ],
      _ConcertPhase.result => [
        OutlinedButton.icon(
          onPressed: () => setState(() => _phase = _ConcertPhase.select),
          icon: const Icon(Symbols.arrow_back),
          label: const Text('返回调整'),
        ),
        OutlinedButton.icon(
          onPressed: _showEmotionCurveDialog,
          icon: const Icon(Symbols.graphic_eq),
          label: const Text('情绪曲线'),
        ),
        OutlinedButton.icon(
          onPressed: _saveResultAsPlaylist,
          icon: const Icon(Symbols.playlist_add),
          label: const Text('保存为歌单'),
        ),
        FilledButton.icon(
          onPressed: _startShow,
          icon: const Icon(Symbols.play_arrow),
          label: const Text('开演'),
        ),
      ],
    };
    // 演出进行中给出显式出口：结束只退出演出状态，队列与播放保持不变
    if (!ConcertSession.instance.isActive) return actions;
    return [
      OutlinedButton.icon(
        onPressed: _endShow,
        icon: const Icon(Symbols.stop),
        label: const Text('结束演出'),
      ),
      ...actions,
    ];
  }

  void _endShow() {
    ConcertSession.instance.end();
    showTextOnSnackBar('演出已结束');
  }

  Widget _buildSelectBody(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_programs.isNotEmpty) ...[
          _sectionLabel(context, '最近的演出'),
          const SizedBox(height: Spacing.sm),
          _buildRecentPrograms(),
          const SizedBox(height: Spacing.lg),
        ],
        _sectionLabel(context, '选择素材'),
        const SizedBox(height: Spacing.sm),
        Wrap(
          spacing: 8.0,
          runSpacing: 8.0,
          children: [
            _libraryPill(context),
            for (final kind in _SourceKind.values) _sourcePill(context, kind),
          ],
        ),
        if (_hasSelection) _selectionHint(scheme),
        const SizedBox(height: Spacing.md),
        Expanded(child: _buildSourceList()),
      ],
    );
  }

  Widget _selectionHint(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.only(top: Spacing.sm),
      child: Row(
        children: [
          Text(
            '已选 ${_collectSelectedAudios().length} 首乐曲',
            style: TextStyle(
              fontSize: AppType.caption,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: Spacing.md),
          TextButton(
            onPressed: _clearSelection,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 32),
            ),
            child: const Text('清除'),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: AppType.caption,
        fontWeight: AppType.weightSemibold,
        letterSpacing: 1.2,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _buildRecentPrograms() {
    return SizedBox(
      height: 84,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _programs.length,
        separatorBuilder: (_, _) => const SizedBox(width: Spacing.sm),
        itemBuilder: (context, index) => _recentProgramCard(_programs[index]),
      ),
    );
  }

  Widget _recentProgramCard(ConcertProgram program) {
    return SizedBox(
      width: 220,
      child: InkWell(
        borderRadius: AppRadius.mdCircular,
        hoverColor: schemeHover(context),
        onTap: () => _restoreProgram(program),
        child: Container(
          padding: const EdgeInsets.all(Spacing.md),
          decoration: _recentProgramDecoration(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _recentProgramTitleRow(program),
              const Spacer(),
              _recentProgramMeta(program),
            ],
          ),
        ),
      ),
    );
  }

  BoxDecoration _recentProgramDecoration() {
    return BoxDecoration(
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      borderRadius: AppRadius.mdCircular,
      border: Border.all(color: Colors.transparent),
    );
  }

  Widget _recentProgramTitleRow(ConcertProgram program) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Text(
            program.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: AppType.body,
              fontWeight: AppType.weightMedium,
              color: scheme.onSurface,
            ),
          ),
        ),
        SizedBox(
          width: 24,
          height: 24,
          child: IconButton(
            padding: EdgeInsets.zero,
            iconSize: 16,
            tooltip: '开演',
            onPressed: () => _restoreAndStart(program),
            icon: Icon(Symbols.play_arrow, color: scheme.primary),
          ),
        ),
        SizedBox(
          width: 24,
          height: 24,
          child: IconButton(
            padding: EdgeInsets.zero,
            iconSize: 16,
            tooltip: '删除',
            onPressed: () => _deleteProgram(program.id),
            icon: Icon(Symbols.close, color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  Widget _recentProgramMeta(ConcertProgram program) {
    final created = program.createdAt;
    return Text(
      '${program.paths.length} 首 · '
      '${created.month}/${created.day} '
      '${created.hour.toString().padLeft(2, '0')}:'
      '${created.minute.toString().padLeft(2, '0')}',
      style: TextStyle(
        fontSize: AppType.microlabel,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _libraryPill(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isSelected = _entireLibrary;
    return OutlinedButton.icon(
      onPressed: () => setState(() {
        _entireLibrary = !_entireLibrary;
        if (_entireLibrary) {
          selectedFolders.clear();
          selectedArtists.clear();
          selectedAlbums.clear();
          selectedPlaylists.clear();
        }
      }),
      icon: const Icon(Symbols.library_music, size: 18),
      label: const Text('整个曲库'),
      style: ButtonStyle(
        foregroundColor: WidgetStatePropertyAll(
          isSelected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
        ),
        backgroundColor: WidgetStatePropertyAll(
          isSelected
              ? scheme.secondaryContainer
              : scheme.surfaceContainerHighest,
        ),
        side: WidgetStatePropertyAll(
          BorderSide(color: isSelected ? scheme.primary : scheme.outline),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
      ),
    );
  }

  Widget _sourcePill(BuildContext context, _SourceKind kind) {
    final scheme = Theme.of(context).colorScheme;
    final isSelected = kind == _sourceKind && !_entireLibrary;
    final badgeCount = _kindSelectionCount(kind);
    return OutlinedButton.icon(
      onPressed: () => setState(() {
        _sourceKind = kind;
        _entireLibrary = false;
      }),
      icon: Icon(kind.icon, size: 18),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(kind.label),
          if (badgeCount > 0) ...[
            const SizedBox(width: 6),
            _sourceCountBadge(scheme, isSelected, badgeCount),
          ],
        ],
      ),
      style: _sourcePillStyle(scheme, isSelected),
    );
  }

  Widget _sourceCountBadge(ColorScheme scheme, bool isSelected, int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: isSelected
            ? scheme.primary
            : scheme.onSurfaceVariant.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$count',
        style: TextStyle(
          fontSize: AppType.microlabel,
          height: 1.4,
          color: isSelected ? scheme.onPrimary : scheme.onSurface,
        ),
      ),
    );
  }

  ButtonStyle _sourcePillStyle(ColorScheme scheme, bool isSelected) {
    return ButtonStyle(
      foregroundColor: WidgetStatePropertyAll(
        isSelected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
      ),
      backgroundColor: WidgetStatePropertyAll(
        isSelected ? scheme.secondaryContainer : scheme.surfaceContainerHighest,
      ),
      side: WidgetStatePropertyAll(
        BorderSide(color: isSelected ? scheme.primary : scheme.outline),
      ),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
      ),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
    );
  }

  ({List<_SourceEntry> entries, Set<String> selected}) _currentSourceEntries() {
    switch (_sourceKind) {
      case _SourceKind.folders:
        return (entries: _folderSourceEntries(), selected: selectedFolders);
      case _SourceKind.artists:
        return (entries: _artistSourceEntries(), selected: selectedArtists);
      case _SourceKind.albums:
        return (entries: _albumSourceEntries(), selected: selectedAlbums);
      case _SourceKind.playlists:
        return (entries: _playlistSourceEntries(), selected: selectedPlaylists);
    }
  }

  List<_SourceEntry> _folderSourceEntries() {
    return [
      for (final folder in AudioLibrary.instance.folders)
        _SourceEntry(
          key: folder.path,
          title: folder.displayName,
          count: folder.audios.length,
          icon: Symbols.folder,
        ),
    ];
  }

  List<_SourceEntry> _artistSourceEntries() {
    return [
      for (final artist in AudioLibrary.instance.artistCollection.values)
        _SourceEntry(
          key: artist.name,
          title: artist.name,
          count: artist.works.length,
          icon: Symbols.artist,
        ),
    ]..sort((a, b) => a.title.compareTo(b.title));
  }

  List<_SourceEntry> _albumSourceEntries() {
    return [
      for (final album in AudioLibrary.instance.albumCollection.values)
        _SourceEntry(
          key: album.name,
          title: album.name,
          count: album.works.length,
          icon: Symbols.album,
        ),
    ]..sort((a, b) => a.title.compareTo(b.title));
  }

  List<_SourceEntry> _playlistSourceEntries() {
    return [
      for (final playlist in playlists)
        _SourceEntry(
          key: playlist.name,
          title: playlist.name,
          count: playlist.paths.length,
          icon: Symbols.list,
        ),
    ];
  }

  Widget _buildSourceList() {
    final (:entries, selected: selected) = _currentSourceEntries();
    if (entries.isEmpty) {
      return Center(
        child: Text(
          '这里还没有内容，先去曲库页添加音乐文件夹',
          style: TextStyle(
            fontSize: AppType.body,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    final stackedEnabled =
        AppSettings.instance.enableStackedScrollEffect &&
        !MediaQuery.disableAnimationsOf(context);
    return Material(
      type: MaterialType.transparency,
      child: stackedEnabled
          ? StackedListView(
              controller: _sourceListController,
              itemExtent: _audioRowExtent,
              itemCount: entries.length,
              padding: const EdgeInsets.only(bottom: Spacing.bottomNav),
              itemBuilder: (context, index) =>
                  _sourceEntryTile(entries[index], selected),
            )
          : ListView.builder(
              controller: _sourceListController,
              itemCount: entries.length,
              padding: const EdgeInsets.only(bottom: Spacing.bottomNav),
              itemBuilder: (context, index) =>
                  _sourceEntryTile(entries[index], selected),
            ),
    );
  }

  Widget _sourceEntryTile(_SourceEntry entry, Set<String> selected) {
    final isSelected = selected.contains(entry.key);
    return InkWell(
      borderRadius: AppRadius.smCircular,
      hoverColor: schemeHover(context),
      onTap: () {
        isSelected ? selected.remove(entry.key) : selected.add(entry.key);
        setState(() {});
      },
      child: AnimatedContainer(
        duration: MotionDuration.base,
        curve: MotionCurve.standard,
        height: 64.0,
        padding: const EdgeInsets.symmetric(horizontal: 8.0),
        decoration: BoxDecoration(
          color: isSelected
              ? Theme.of(context).colorScheme.secondaryContainer
              : Colors.transparent,
          borderRadius: AppRadius.smCircular,
        ),
        child: Row(
          children: [
            Icon(
              entry.icon,
              size: 24,
              color: isSelected
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 16.0),
            Expanded(child: _sourceEntryTexts(entry)),
            _sourceCheckIcon(context, isSelected),
          ],
        ),
      ),
    );
  }

  Widget _sourceCheckIcon(BuildContext context, bool isSelected) {
    final scheme = Theme.of(context).colorScheme;
    return Icon(
      isSelected ? Symbols.check_circle : Symbols.circle,
      size: 22,
      color: isSelected
          ? scheme.primary
          : scheme.onSurfaceVariant.withValues(alpha: 0.45),
    );
  }

  Widget _sourceEntryTexts(_SourceEntry entry) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          entry.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: AppType.subtitle,
            fontWeight: AppType.weightMedium,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        Text(
          '${entry.count} 首',
          style: TextStyle(
            fontSize: AppType.caption,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Color schemeHover(BuildContext context) =>
      Theme.of(context).colorScheme.onSurface.withValues(alpha: Alpha.hover);

  String _climaxLabel(double value) => value < 0.7
      ? '偏早'
      : value < 0.88
      ? '适中'
      : '压轴';

  String _contrastLabel(double value) => value < 0.34
      ? '平缓'
      : value < 0.67
      ? '适中'
      : '强烈';

  String _smoothnessLabel(double value) => value < 0.34
      ? '叙事优先'
      : value < 0.67
      ? '均衡'
      : '顺滑优先';

  List<Widget> _styleChips(
    ColorScheme scheme,
    List<(String, int)> options,
    int current,
    ValueChanged<int> onSelected,
  ) {
    return [
      for (final (name, value) in options)
        _sizeChip(
          scheme,
          value,
          null,
          label: name,
          isSelectedOverride: current == value,
          useOverride: true,
          onSelected: () => onSelected(value),
        ),
    ];
  }

  Widget _buildStyleChipsRow(
    ColorScheme scheme, {
    required String label,
    required List<(String, int)> options,
    required int current,
    required ValueChanged<int> onSelected,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: TextStyle(
                fontSize: AppType.body,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.xs,
              children: _styleChips(scheme, options, current, onSelected),
            ),
          ),
        ],
      ),
    );
  }

  void _bindKnob(void Function() apply, StateSetter? dialogSetState) {
    setState(apply);
    dialogSetState?.call(() {});
  }

  List<Widget> _advancedSliderRows({
    VoidCallback? onCommit,
    StateSetter? dialogSetState,
  }) {
    return [
      _SliderRow(
        label: '压轴时机',
        detail: _climaxLabel(_climaxPosition),
        value: _climaxPosition,
        min: 0.55,
        max: 0.95,
        onChanged: (value) =>
            _bindKnob(() => _climaxPosition = value, dialogSetState),
        onChangedEnd: onCommit == null ? null : (_) => onCommit(),
      ),
      _SliderRow(
        label: '情绪起伏',
        detail: _contrastLabel(_contrast),
        value: _contrast,
        min: 0,
        max: 1,
        onChanged: (value) =>
            _bindKnob(() => _contrast = value, dialogSetState),
        onChangedEnd: onCommit == null ? null : (_) => onCommit(),
      ),
      _SliderRow(
        label: '顺滑度',
        detail: _smoothnessLabel(_smoothness),
        value: _smoothness,
        min: 0,
        max: 1,
        onChanged: (value) =>
            _bindKnob(() => _smoothness = value, dialogSetState),
        onChangedEnd: onCommit == null ? null : (_) => onCommit(),
      ),
    ];
  }

  List<Widget> _advancedStyleChips({
    required ColorScheme scheme,
    VoidCallback? onCommit,
    StateSetter? dialogSetState,
  }) {
    return [
      _buildStyleChipsRow(
        scheme,
        label: '收尾风格',
        options: const [('温暖', 0), ('渐弱', 1), ('燃尽', 2)],
        current: _outroStyle,
        onSelected: (value) {
          setState(() => _outroStyle = value);
          dialogSetState?.call(() {});
          onCommit?.call();
        },
      ),
      _buildStyleChipsRow(
        scheme,
        label: '抽取口味',
        options: const [('全部', 0), ('换口味', 1), ('常听的', 2)],
        current: _taste,
        onSelected: (value) {
          setState(() => _taste = value);
          dialogSetState?.call(() {});
          onCommit?.call();
        },
      ),
    ];
  }

  Widget _buildAdvancedCard(
    ColorScheme scheme, {
    VoidCallback? onCommit,
    StateSetter? dialogSetState,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.lg,
        vertical: Spacing.xs,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: AppRadius.mdCircular,
      ),
      child: Column(
        children: [
          ..._advancedSliderRows(
            onCommit: onCommit,
            dialogSetState: dialogSetState,
          ),
          _buildSetSizeRow(
            scheme,
            onCommitted: onCommit,
            dialogSetState: dialogSetState,
          ),
          ..._advancedStyleChips(
            scheme: scheme,
            onCommit: onCommit,
            dialogSetState: dialogSetState,
          ),
        ],
      ),
    );
  }

  List<Widget> _setSizeChips(
    ColorScheme scheme,
    VoidCallback? onCommitted,
    StateSetter? dialogSetState,
  ) {
    return [
      for (final option in const [0, 15, 30, 60])
        _sizeChip(scheme, option, onCommitted, dialogSetState: dialogSetState),
    ];
  }

  Widget _buildSetSizeRow(
    ColorScheme scheme, {
    VoidCallback? onCommitted,
    StateSetter? dialogSetState,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(
              '演出规模',
              style: TextStyle(
                fontSize: AppType.body,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.xs,
              children: _setSizeChips(scheme, onCommitted, dialogSetState),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sizeChip(
    ColorScheme scheme,
    int value,
    VoidCallback? onCommitted, {
    String? label,
    bool isSelectedOverride = false,
    bool useOverride = false,
    VoidCallback? onSelected,
    StateSetter? dialogSetState,
  }) {
    final isSelected = useOverride ? isSelectedOverride : _setSize == value;
    final effectiveLabel = label ?? (value == 0 ? '不限' : '$value 首');
    return InkWell(
      borderRadius: AppRadius.smCircular,
      onTap: () {
        if (onSelected != null) {
          onSelected();
          return;
        }
        if (isSelected) return;
        setState(() => _setSize = value);
        dialogSetState?.call(() {});
        onCommitted?.call();
      },
      child: AnimatedContainer(
        duration: MotionDuration.base,
        curve: MotionCurve.standard,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: _sizeChipDecoration(scheme, isSelected),
        child: Text(
          effectiveLabel,
          style: _sizeChipTextStyle(scheme, isSelected),
        ),
      ),
    );
  }

  BoxDecoration _sizeChipDecoration(ColorScheme scheme, bool isSelected) {
    return BoxDecoration(
      color: isSelected
          ? scheme.secondaryContainer
          : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: AppRadius.smCircular,
      border: Border.all(
        color: isSelected ? scheme.primary : scheme.outlineVariant,
      ),
    );
  }

  TextStyle _sizeChipTextStyle(ColorScheme scheme, bool isSelected) {
    return TextStyle(
      fontSize: AppType.caption,
      fontWeight: isSelected ? AppType.weightSemibold : AppType.weightRegular,
      color: isSelected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
    );
  }

  Widget _buildAnalyzingBody(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '正在分析乐曲特征 $_analyzedCount / $_totalCount',
            style: TextStyle(
              fontSize: AppType.subtitle,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: Spacing.lg),
          SizedBox(
            width: 320,
            child: LinearProgressIndicator(
              value: _totalCount == 0 ? null : _analyzedCount / _totalCount,
            ),
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            '首次分析需要完整解码音频，之后走缓存会快很多',
            style: TextStyle(
              fontSize: AppType.caption,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  // ===== 结果页：演出节目单 =====

  List<ConcertSection> _computeSections(int count) {
    return concertSectionsFor(count: count, climaxPosition: _climaxPosition);
  }

  Widget _buildResultBody(BuildContext context) {
    final result = _result;
    if (result == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final sections = _computeSections(result.audios.length);
    final layout = concertQueueLayout(result.audios.length, sections);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _adjusterHeader(scheme),
        _adjusterPanel(scheme, result),
        const SizedBox(height: Spacing.xs),
        Expanded(
          child: Material(
            type: MaterialType.transparency,
            child: _buildProgramList(result, sections, layout, scheme),
          ),
        ),
      ],
    );
  }

  Widget _adjusterHeader(ColorScheme scheme) {
    return InkWell(
      borderRadius: AppRadius.mdCircular,
      hoverColor: schemeHover(context),
      onTap: () => setState(() => _adjusterOpen = !_adjusterOpen),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.lg,
          vertical: Spacing.sm + 2,
        ),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: AppRadius.mdCircular,
        ),
        child: Row(
          children: [
            Icon(Icons.tune, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: Spacing.sm),
            Text(
              '调节',
              style: TextStyle(
                fontSize: AppType.body,
                fontWeight: AppType.weightMedium,
                color: scheme.onSurface,
              ),
            ),
            const Spacer(),
            _adjusterTrailing(scheme),
          ],
        ),
      ),
    );
  }

  Widget _adjusterTrailing(ColorScheme scheme) {
    if (_replanning) {
      return SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary),
      );
    }
    return AnimatedRotation(
      duration: MotionDuration.base,
      curve: MotionCurve.standard,
      turns: _adjusterOpen ? 0.5 : 0.0,
      child: Icon(
        Symbols.keyboard_arrow_down,
        size: 20,
        color: scheme.onSurfaceVariant,
      ),
    );
  }

  Widget _adjusterPanel(ColorScheme scheme, SmartSortResult result) {
    return AnimatedSize(
      duration: MotionDuration.base,
      curve: MotionCurve.standard,
      alignment: Alignment.topCenter,
      child: _adjusterOpen
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: Spacing.sm),
                _curveCard(scheme, result),
                const SizedBox(height: Spacing.sm),
                _buildAdvancedCard(scheme, onCommit: _replanQuietly),
              ],
            )
          : const SizedBox.shrink(),
    );
  }

  Widget _curveCard(ColorScheme scheme, SmartSortResult result) {
    return Stack(
      children: [
        Container(
          height: 180,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
            borderRadius: AppRadius.mdCircular,
            border: Border.all(color: scheme.outlineVariant),
          ),
          padding: const EdgeInsets.all(Spacing.md),
          child: _tappableCurve(
            idealCurve: result.idealCurve,
            actualCurve: result.actualCurve,
            highlightIndex: _highlightIndex,
            onTap: _locateFromChart,
          ),
        ),
        Positioned(
          top: Spacing.sm,
          right: Spacing.md,
          child: Row(
            children: [
              _LegendDot(color: scheme.outline, dashed: true, label: '目标'),
              const SizedBox(width: Spacing.md),
              _LegendDot(color: scheme.primary, label: '实际'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildProgramList(
    SmartSortResult result,
    List<ConcertSection> sections,
    List<int> layout,
    ColorScheme scheme,
  ) {
    final stackedEnabled =
        AppSettings.instance.enableStackedScrollEffect &&
        !MediaQuery.disableAnimationsOf(context);
    final extents = <double>[
      for (final value in layout)
        value < 0 ? kConcertActHeaderExtent : _audioRowExtent,
      _footerRowExtent,
    ];
    final tops = <double>[0.0];
    for (final extent in extents) {
      tops.add(tops.last + extent);
    }
    final listView = ListView.builder(
      controller: _resultListController,
      physics: stackedEnabled ? const SmoothScrollPhysics() : null,
      itemCount: layout.length + 1,
      // 底部预留 mini 播放器悬浮高度与收尾小字的空间。
      padding: const EdgeInsets.only(bottom: Spacing.bottomNav),
      itemBuilder: (context, index) => _programListItem(
        result: result,
        sections: sections,
        layout: layout,
        scheme: scheme,
        index: index,
        stackedEnabled: stackedEnabled,
        extents: extents,
        tops: tops,
      ),
    );
    // 与 StackedListView 一致：作用域内跳过入场动画，避免与堆叠变换叠加。
    if (!stackedEnabled) return listView;
    return StackedEffectScope(child: listView);
  }

  Widget _programListRow(
    SmartSortResult result,
    List<ConcertSection> sections,
    List<int> layout,
    ColorScheme scheme,
    int index,
  ) {
    if (index == layout.length) {
      return SizedBox(
        height: _footerRowExtent,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.lg,
            Spacing.lg,
            Spacing.lg,
            Spacing.sm,
          ),
          child: Text(
            '仅影响本次播放队列，你的歌单不会被改动。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: AppType.microlabel,
              letterSpacing: 0.2,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ),
      );
    }
    final value = layout[index];
    if (value < 0) {
      final section = sections[-value - 1];
      return SizedBox(
        height: kConcertActHeaderExtent,
        child: _ProgramHeader(name: section.name, count: section.count),
      );
    }
    return AudioTile(
      audioIndex: value,
      playlist: result.audios,
      focus: value == _highlightIndex,
      leading: _OrderBadge(order: value + 1),
    );
  }

  Widget _programListItem({
    required SmartSortResult result,
    required List<ConcertSection> sections,
    required List<int> layout,
    required ColorScheme scheme,
    required int index,
    required bool stackedEnabled,
    required List<double> extents,
    required List<double> tops,
  }) {
    final child = _programListRow(result, sections, layout, scheme, index);
    if (!stackedEnabled) return child;
    return AnimatedBuilder(
      animation: _resultListController,
      child: child,
      builder: (context, child) {
        final positions = _resultListController.positions;
        if (positions.isEmpty) return child!;
        final position = positions.first;
        final viewportHeight = position.viewportDimension;
        final extent = extents[index];
        if (viewportHeight < extent * 2) return child!;
        return StackedItemTransform(
          itemTop: tops[index] - position.pixels,
          itemExtent: extent,
          viewportHeight: viewportHeight,
          child: child!,
        );
      },
    );
  }
}

class _ProgramHeader extends StatelessWidget {
  const _ProgramHeader({required this.name, required this.count});

  final String name;
  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.md,
        Spacing.lg,
        Spacing.md,
        Spacing.xs,
      ),
      child: Row(
        children: [
          Text(
            name,
            style: TextStyle(
              fontSize: AppType.caption,
              fontWeight: AppType.weightSemibold,
              letterSpacing: 1.4,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: Spacing.md),
          Expanded(child: Container(height: 1, color: scheme.outlineVariant)),
          const SizedBox(width: Spacing.md),
          Text(
            '$count 首',
            style: TextStyle(
              fontSize: AppType.microlabel,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _SourceEntry {
  const _SourceEntry({
    required this.key,
    required this.title,
    required this.count,
    required this.icon,
  });

  final String key;
  final String title;
  final int count;
  final IconData icon;
}

class _OrderBadge extends StatelessWidget {
  const _OrderBadge({required this.order});

  final int order;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 32,
      child: Center(
        child: Text(
          '$order',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: AppType.subtitle,
            fontWeight: AppType.weightSemibold,
            color: scheme.primary,
          ),
        ),
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.detail,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.onChangedEnd,
  });

  final String label;
  final String detail;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangedEnd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: TextStyle(
              fontSize: AppType.body,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
            onChangeEnd: onChangedEnd,
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            detail,
            textAlign: TextAlign.end,
            style: TextStyle(
              fontSize: AppType.caption,
              color: scheme.primary,
              fontWeight: AppType.weightMedium,
            ),
          ),
        ),
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({
    required this.color,
    required this.label,
    this.dashed = false,
  });

  final Color color;
  final String label;
  final bool dashed;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: 3,
          decoration: BoxDecoration(
            color: dashed ? Colors.transparent : color,
            border: dashed
                ? Border(top: BorderSide(color: color, width: 2))
                : null,
          ),
        ),
        const SizedBox(width: Spacing.xs),
        Text(
          label,
          style: TextStyle(fontSize: AppType.microlabel, color: color),
        ),
      ],
    );
  }
}

class _CurveChart extends StatelessWidget {
  const _CurveChart({
    required this.idealCurve,
    required this.actualCurve,
    this.highlightIndex = -1,
  });

  final List<double> idealCurve;
  final List<double> actualCurve;
  final int highlightIndex;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CustomPaint(
      painter: _CurveChartPainter(
        idealCurve: idealCurve,
        actualCurve: actualCurve,
        idealColor: scheme.outline,
        actualColor: scheme.primary,
        highlightColor: scheme.secondary,
        highlightIndex: highlightIndex,
      ),
      size: Size.infinite,
    );
  }
}

class _CurveChartPainter extends CustomPainter {
  const _CurveChartPainter({
    required this.idealCurve,
    required this.actualCurve,
    required this.idealColor,
    required this.actualColor,
    required this.highlightColor,
    required this.highlightIndex,
  });

  final List<double> idealCurve;
  final List<double> actualCurve;
  final Color idealColor;
  final Color actualColor;
  final Color highlightColor;
  final int highlightIndex;

  static const double _dashLength = 5;
  static const double _dashGap = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final all = [...idealCurve, ...actualCurve];
    if (all.isEmpty) return;
    var minValue = all.reduce(math.min);
    var maxValue = all.reduce(math.max);
    if (maxValue - minValue < 1e-6) {
      maxValue += 1;
      minValue -= 1;
    }
    const headroom = 8.0;
    _paintIdeal(canvas, size, minValue, maxValue, headroom);
    _paintActual(canvas, size, minValue, maxValue, headroom);
    _paintHighlight(canvas, size, minValue, maxValue, headroom);
  }

  Offset _pointAt(
    int index,
    List<double> curve,
    Size size,
    double minValue,
    double maxValue,
    double headroom,
  ) {
    final count = curve.length;
    final x = count <= 1 ? size.width / 2 : size.width * index / (count - 1);
    final normalized = (curve[index] - minValue) / (maxValue - minValue);
    return Offset(
      x,
      size.height - headroom - normalized * (size.height - headroom * 2),
    );
  }

  Path _polyline(
    List<double> curve,
    Size size,
    double minValue,
    double maxValue,
    double headroom,
  ) {
    final path = Path()
      ..moveTo(
        _pointAt(0, curve, size, minValue, maxValue, headroom).dx,
        _pointAt(0, curve, size, minValue, maxValue, headroom).dy,
      );
    for (var index = 1; index < curve.length; index++) {
      final point = _pointAt(index, curve, size, minValue, maxValue, headroom);
      path.lineTo(point.dx, point.dy);
    }
    return path;
  }

  void _paintIdeal(
    Canvas canvas,
    Size size,
    double minValue,
    double maxValue,
    double headroom,
  ) {
    if (idealCurve.length < 2) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = idealColor.withValues(alpha: 0.85);
    final path = _polyline(idealCurve, size, minValue, maxValue, headroom);
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = math.min(distance + _dashLength, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance += _dashLength + _dashGap;
      }
    }
  }

  void _paintActual(
    Canvas canvas,
    Size size,
    double minValue,
    double maxValue,
    double headroom,
  ) {
    if (actualCurve.length < 2) return;
    canvas.drawPath(
      _polyline(actualCurve, size, minValue, maxValue, headroom),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..color = actualColor
        ..strokeCap = StrokeCap.round,
    );
    final dotPaint = Paint()..color = actualColor;
    for (var index = 0; index < actualCurve.length; index++) {
      canvas.drawCircle(
        _pointAt(index, actualCurve, size, minValue, maxValue, headroom),
        3,
        dotPaint,
      );
    }
  }

  void _paintHighlight(
    Canvas canvas,
    Size size,
    double minValue,
    double maxValue,
    double headroom,
  ) {
    if (highlightIndex < 0 || highlightIndex >= actualCurve.length) return;
    final point = _pointAt(
      highlightIndex,
      actualCurve,
      size,
      minValue,
      maxValue,
      headroom,
    );
    canvas.drawLine(
      Offset(point.dx, headroom),
      Offset(point.dx, size.height - headroom),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = highlightColor.withValues(alpha: 0.45),
    );
    canvas.drawCircle(point, 5.5, Paint()..color = highlightColor);
    canvas.drawCircle(point, 3, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_CurveChartPainter oldDelegate) =>
      oldDelegate.idealCurve != idealCurve ||
      oldDelegate.actualCurve != actualCurve ||
      oldDelegate.actualColor != actualColor ||
      oldDelegate.idealColor != idealColor ||
      oldDelegate.highlightIndex != highlightIndex;
}

class _SaveConcertPlaylistDialog extends StatefulWidget {
  const _SaveConcertPlaylistDialog({
    required this.initialName,
    required this.existingNames,
  });

  final String initialName;
  final Set<String> existingNames;

  @override
  State<_SaveConcertPlaylistDialog> createState() =>
      _SaveConcertPlaylistDialogState();
}

class _SaveConcertPlaylistDialogState
    extends State<_SaveConcertPlaylistDialog> {
  late final TextEditingController _controller;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _controller.text.length,
    );
    if (hasEquivalentPlaylistName(
      existingNames: widget.existingNames,
      targetName: widget.initialName,
    )) {
      _errorText = '该名称已存在';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _trimmedName => _controller.text.trim();

  bool get _canSubmit {
    final name = _trimmedName;
    return name.isNotEmpty &&
        !hasEquivalentPlaylistName(
          existingNames: widget.existingNames,
          targetName: name,
        );
  }

  void _onNameChanged(String value) {
    final name = value.trim();
    setState(() {
      if (name.isEmpty) {
        _errorText = null;
        return;
      }
      _errorText =
          hasEquivalentPlaylistName(
            existingNames: widget.existingNames,
            targetName: name,
          )
          ? '该名称已存在'
          : null;
    });
  }

  void _submit() {
    final name = _trimmedName;
    if (name.isEmpty) {
      setState(() => _errorText = '请输入歌单名称');
      return;
    }
    if (hasEquivalentPlaylistName(
      existingNames: widget.existingNames,
      targetName: name,
    )) {
      setState(() => _errorText = '该名称已存在');
      return;
    }
    Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('存为歌单？'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '把这场演出的顺序存成新歌单，原来的歌单不会被改。',
              style: TextStyle(
                fontSize: AppType.body,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Spacing.md),
            Focus(
              onFocusChange: HotkeysHelper.onFocusChanges,
              child: TextField(
                autofocus: true,
                controller: _controller,
                onChanged: _onNameChanged,
                onSubmitted: (_) {
                  if (_canSubmit) _submit();
                },
                decoration: InputDecoration(
                  labelText: '歌单名称',
                  border: const OutlineInputBorder(),
                  errorText: _errorText,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('跳过'),
        ),
        FilledButton(
          onPressed: _canSubmit ? _submit : null,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
