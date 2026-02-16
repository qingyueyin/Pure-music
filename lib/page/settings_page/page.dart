import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/page/settings_page/artist_separator_editor.dart';
import 'package:pure_music/page/settings_page/check_update.dart';
import 'package:pure_music/page/settings_page/create_issue.dart';
import 'package:pure_music/page/settings_page/other_settings.dart';
import 'package:pure_music/page/settings_page/theme_settings.dart';
import 'package:flutter/material.dart';

class _SettingsSectionHeader extends StatelessWidget {
  const _SettingsSectionHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8.0),
      child: Text(
        text,
        style: TextStyle(
          color: scheme.onSurface.withValues(alpha: 0.75),
          fontSize: 14.0,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: "设置",
      actions: const [],
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96.0),
        children: [
          const _SettingsSectionHeader("库与扫描"),
          const SizedBox(height: 16.0),
          DefaultLyricSourceControl(),

          const SizedBox(height: 24.0),
          const _SettingsSectionHeader("播放"),
          const EqBypassSwitch(),

          const SizedBox(height: 24.0),
          const _SettingsSectionHeader("外观"),
          DynamicThemeSwitch(),
          const SizedBox(height: 16.0),
          ThemeModeControl(),
          const SizedBox(height: 16.0),
          const AppearanceAdvancedSettingsTile(),

          const SizedBox(height: 24.0),
          const _SettingsSectionHeader("高级与关于"),
          ArtistSeparatorEditor(),
          const SizedBox(height: 16.0),
          CreateIssueTile(),
          const SizedBox(height: 16.0),
          CheckForUpdate(),
        ],
      ),
    );
  }
}
