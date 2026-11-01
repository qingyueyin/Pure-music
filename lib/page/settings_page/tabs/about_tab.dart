import 'dart:async';

import 'package:flutter/material.dart';
import 'package:github/github.dart' as gh;
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/settings_tile.dart';
import 'package:pure_music/component/stacked_list_view.dart'
    show SmoothScrollListView;
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/update_checker.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/page/settings_page/check_update.dart';
import 'package:pure_music/page/settings_page/create_issue.dart';
import 'package:pure_music/page/settings_page/tabs/settings_section_header.dart';
import 'package:pure_music/services/native/platform_service.dart';

class AboutTabContent extends StatelessWidget {
  const AboutTabContent({
    super.key,
    this.contributorsSection = const _AboutContributorsSection(),
  });

  final Widget contributorsSection;

  @override
  Widget build(BuildContext context) {
    return SmoothScrollListView(
      padding: const EdgeInsets.only(bottom: 96.0, right: 20),
      children: [
        const SettingsSectionHeader('更新'),
        const SizedBox(height: 4.0),
        const _AboutVersionItem(),
        const SizedBox(height: 16.0),
        const _AboutUpdateChannelItem(),
        const SizedBox(height: 16.0),
        const _AboutAutoUpdateItem(),
        const SizedBox(height: 24.0),
        const SettingsSectionHeader('相关链接'),
        const SizedBox(height: 4.0),
        const _AboutLinkItem(
          title: '官方网站',
          url: 'https://qingyueyin.github.io/Pure-music/',
          actionLabel: '访问官网',
          icon: Symbols.language,
        ),
        const SizedBox(height: 16.0),
        const _AboutLinkItem(
          title: '项目主页',
          url: 'https://github.com/qingyueyin/Pure-music',
          actionLabel: '打开仓库',
          icon: Symbols.code,
        ),
        const SizedBox(height: 16.0),
        const _AboutLinkItem(
          title: '交流群组',
          url: 'https://t.me/+NsZamWiEKh5lOWNl',
          actionLabel: '加入群组',
          icon: Symbols.send,
        ),
        const SizedBox(height: 16.0),
        const CreateIssueTile(),
        contributorsSection,
      ],
    );
  }
}

class _AboutContributorsSection extends StatefulWidget {
  const _AboutContributorsSection();

  @override
  State<_AboutContributorsSection> createState() =>
      _AboutContributorsSectionState();
}

class _AboutContributorsSectionState extends State<_AboutContributorsSection> {
  static List<_AboutContributor>? _cachedContributors;
  static Future<List<_AboutContributor>>? _pendingRequest;

  List<_AboutContributor>? _contributors;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _contributors = _cachedContributors;
    if (_contributors == null) _loadContributors();
  }

  Future<void> _loadContributors() async {
    setState(() {
      _error = null;
      _contributors = null;
    });
    try {
      final contributors = await _getContributors();
      if (!mounted) return;
      setState(() => _contributors = contributors);
    } catch (error, trace) {
      log.settings.warn(
        'legacy',
        '[About] contributors request failed: ${error.runtimeType}',
      );
      log.settings.debug('legacy', trace.toString());
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  static Future<List<_AboutContributor>> _getContributors() async {
    final cached = _cachedContributors;
    if (cached != null) return cached;

    final pending = _pendingRequest;
    if (pending != null) return pending;

    final request = _fetchContributors();
    _pendingRequest = request;
    try {
      final contributors = await request;
      _cachedContributors = contributors;
      return contributors;
    } finally {
      if (identical(_pendingRequest, request)) _pendingRequest = null;
    }
  }

  static Future<List<_AboutContributor>> _fetchContributors() async {
    final slug = gh.RepositorySlug.full(AppPreference.defaultUpdateRepoSlug);
    final response = await AppSettings.github.repositories
        .listContributors(slug, anon: true)
        .toList()
        .timeout(const Duration(seconds: 15));
    final contributors = response
        .where((item) {
          final login = item.login?.trim();
          final type = item.type?.toLowerCase();
          return login != null &&
              login.isNotEmpty &&
              type != 'bot' &&
              !login.toLowerCase().endsWith('[bot]');
        })
        .map(_AboutContributor.fromGitHub)
        .toList();
    contributors.sort((left, right) {
      final contributionOrder = right.contributions.compareTo(
        left.contributions,
      );
      if (contributionOrder != 0) return contributionOrder;
      return left.login.toLowerCase().compareTo(right.login.toLowerCase());
    });
    return List.unmodifiable(contributors);
  }

  @override
  Widget build(BuildContext context) {
    final contributors = _contributors;
    if (_error != null) return _errorView;
    if (contributors == null) {
      return const Padding(
        padding: EdgeInsets.only(top: 24.0),
        child: Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ),
      );
    }
    if (contributors.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SettingsSectionHeader('贡献者'),
          const SizedBox(height: 8.0),
          LayoutBuilder(
            builder: (context, constraints) => _contributorWrap(constraints),
          ),
        ],
      ),
    );
  }

  Widget get _errorView {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SettingsSectionHeader('贡献者'),
          const SizedBox(height: 8.0),
          Center(
            child: Column(
              children: [
                Icon(Symbols.wifi_off, size: 28, color: scheme.outline),
                const SizedBox(height: 8.0),
                Text('加载失败', style: TextStyle(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 8.0),
                TextButton.icon(
                  onPressed: _loadContributors,
                  icon: const Icon(Symbols.refresh, size: 16),
                  label: const Text('重试'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _contributorWrap(BoxConstraints constraints) {
    final textScale = MediaQuery.textScalerOf(
      context,
    ).scale(1.0).clamp(1.0, 2.0);
    final minCellWidth = 104.0 * textScale;
    final columns = ((constraints.maxWidth + Spacing.sm) /
            (minCellWidth + Spacing.sm))
        .floor()
        .clamp(1, 6);
    return Wrap(
      spacing: Spacing.sm,
      runSpacing: Spacing.sm,
      children: [
        for (final contributor in _contributors!)
          _ContributorTile(
            contributor: contributor,
            width: tileWidth(columns, constraints),
          ),
      ],
    );
  }

  double tileWidth(int columns, BoxConstraints constraints) {
    return (constraints.maxWidth - (columns - 1) * Spacing.sm) / columns;
  }
}

class _AboutContributor {
  const _AboutContributor({
    required this.login,
    required this.avatarUrl,
    required this.profileUrl,
    required this.contributions,
  });

  factory _AboutContributor.fromGitHub(gh.Contributor contributor) {
    final login = contributor.login!.trim();
    return _AboutContributor(
      login: login,
      avatarUrl: contributor.avatarUrl?.trim(),
      profileUrl: contributor.htmlUrl?.trim().isNotEmpty == true
          ? contributor.htmlUrl!.trim()
          : 'https://github.com/$login',
      contributions: contributor.contributions ?? 0,
    );
  }

  final String login;
  final String? avatarUrl;
  final String profileUrl;
  final int contributions;
}

class _ContributorTile extends StatelessWidget {
  const _ContributorTile({required this.contributor, required this.width});

  final _AboutContributor contributor;
  final double width;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      child: Material(
        color: scheme.surfaceContainer,
        borderRadius: AppRadius.mdCircular,
        child: InkWell(
          borderRadius: AppRadius.mdCircular,
          onTap: () => _openProfile(context),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8.0, 16.0, 8.0, 10.0),
            child: Column(
              children: [
                _ContributorAvatar(contributor: contributor),
                const SizedBox(height: 10.0),
                Text(
                  contributor.login,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: AppType.body,
                    fontWeight: AppType.weightMedium,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openProfile(BuildContext context) async {
    final opened = await PlatformService.instance.launchInBrowser(
      contributor.profileUrl,
    );
    if (!opened && context.mounted) {
      showTextOnSnackBar('打开链接失败');
    }
  }
}

class _ContributorAvatar extends StatelessWidget {
  const _ContributorAvatar({required this.contributor});

  final _AboutContributor contributor;

  @override
  Widget build(BuildContext context) {
    final login = contributor.login;
    final initials = login.substring(0, login.length > 2 ? 2 : login.length);
    final avatarUrl = contributor.avatarUrl;
    final scheme = Theme.of(context).colorScheme;
    return CircleAvatar(
      radius: 24,
      backgroundColor: scheme.secondaryContainer,
      foregroundColor: scheme.onSecondaryContainer,
      child: avatarUrl?.isNotEmpty == true
          ? ClipOval(
              child: Image.network(
                avatarUrl!,
                width: 48,
                height: 48,
                fit: BoxFit.cover,
                cacheWidth: 96,
                cacheHeight: 96,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => Text(initials.toUpperCase()),
              ),
            )
          : Text(initials.toUpperCase()),
    );
  }
}

class _AboutVersionItem extends StatefulWidget {
  const _AboutVersionItem();

  @override
  State<_AboutVersionItem> createState() => _AboutVersionItemState();
}

class _AboutVersionItemState extends State<_AboutVersionItem> {
  bool _isChecking = false;

  Future<void> _check() async {
    if (_isChecking) return;
    setState(() => _isChecking = true);

    try {
      final channel = await ensureUpdateChannel(context);
      if (!mounted || channel == null) return;
      final newest = await UpdateChecker.checkForUpdate(channel: channel);
      if (!mounted) return;

      if (newest != null &&
          UpdateChecker.hasNewVersion(newest.tagName, AppSettings.version)) {
        unawaited(
          showDialog<void>(
            context: context,
            builder: (context) =>
                NewestUpdateView(info: newest, channel: channel),
          ),
        );
      } else {
        showTextOnSnackBar('无新版本');
      }
    } catch (err, trace) {
      log.settings.error('legacy', err.toString(), stackTrace: trace);
      if (mounted) showTextOnSnackBar('网络异常');
    } finally {
      if (mounted) setState(() => _isChecking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: '当前版本',
      subtitle: AppSettings.version,
      action: FilledButton.tonalIcon(
        onPressed: _isChecking ? null : _check,
        icon: _isChecking
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Symbols.update, size: 18),
        label: Text(_isChecking ? '检查中' : '检查更新'),
      ),
    );
  }
}

class _AboutUpdateChannelItem extends StatefulWidget {
  const _AboutUpdateChannelItem();

  @override
  State<_AboutUpdateChannelItem> createState() =>
      _AboutUpdateChannelItemState();
}

class _AboutUpdateChannelItemState extends State<_AboutUpdateChannelItem> {
  bool _changing = false;

  Future<void> _chooseChannel() async {
    if (_changing) return;
    setState(() => _changing = true);
    try {
      await chooseAndSaveUpdateChannel(context);
    } finally {
      if (mounted) setState(() => _changing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final channel = UpdateChannel.parse(AppPreference.instance.updateChannel);
    return SettingsTile(
      description: '更新渠道',
      subtitle: channel?.label ?? '首次检查更新时选择',
      action: OutlinedButton.icon(
        onPressed: _changing ? null : _chooseChannel,
        icon: _changing
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Symbols.swap_horiz, size: 18),
        label: Text(
          _changing
              ? '保存中'
              : channel == null
              ? '选择渠道'
              : '切换渠道',
        ),
      ),
    );
  }
}

class _AboutAutoUpdateItem extends StatefulWidget {
  const _AboutAutoUpdateItem();

  @override
  State<_AboutAutoUpdateItem> createState() => _AboutAutoUpdateItemState();
}

class _AboutAutoUpdateItemState extends State<_AboutAutoUpdateItem> {
  @override
  Widget build(BuildContext context) {
    final enabled = AppPreference.instance.autoCheckUpdate;
    return SettingsTile(
      description: '启动时自动检查更新',
      subtitle: enabled ? '已开启' : '已关闭',
      action: Switch(
        value: enabled,
        onChanged: (value) async {
          setState(() => AppPreference.instance.autoCheckUpdate = value);
          await AppPreference.instance.save();
        },
      ),
    );
  }
}

class _AboutLinkItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String url;
  final String actionLabel;

  const _AboutLinkItem({
    required this.icon,
    required this.title,
    required this.url,
    required this.actionLabel,
  });

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: title,
      action: FilledButton.tonalIcon(
        onPressed: () async {
          final opened = await PlatformService.instance.launchInBrowser(url);
          if (!opened) {
            showTextOnSnackBar('打开链接失败');
          }
        },
        icon: Icon(icon, size: 18),
        label: Text(actionLabel),
      ),
    );
  }
}
