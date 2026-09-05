import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/page/settings_page/settings_tabs.dart';
import 'package:flutter/material.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PageScaffold(
      title: '设置',
      subtitle: '外观、歌词、播放',
      actions: [],
      body: SettingsTabs(),
    );
  }
}
