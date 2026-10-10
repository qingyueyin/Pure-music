import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/stacked_list_view.dart'
    show SmoothScrollListView;
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/page/settings_page/settings_group_entry.dart';
import 'package:pure_music/page/settings_page/tabs/settings_section_header.dart';

class AdvancedTabContent extends StatelessWidget {
  const AdvancedTabContent({super.key});

  @override
  Widget build(BuildContext context) {
    return const SmoothScrollListView(
      padding: EdgeInsets.only(bottom: 96.0, right: 20),
      children: [
        _AdvancedGroupEntry(
          icon: Symbols.settings_suggest,
          title: '系统行为',
          subtitle: '关闭窗口、防休眠与日志',
          groupId: 'advanced-system',
        ),
        SizedBox(height: 8.0),
        SettingsSectionHeader('媒体与字体'),
        SizedBox(height: 4.0),
        _AdvancedGroupEntry(
          icon: Symbols.interests,
          title: '媒体解析',
          subtitle: '分隔符、不拆分名单与别名',
          groupId: 'advanced-custom',
        ),
        SizedBox(height: 8.0),
        _AdvancedGroupEntry(
          icon: Symbols.text_fields,
          title: '字体',
          subtitle: '界面与歌词字体',
          groupId: 'advanced-font',
        ),
        SizedBox(height: 8.0),
        _AdvancedGroupEntry(
          icon: Symbols.backup,
          title: '备份',
          subtitle: '导出与导入用户数据',
          groupId: 'advanced-backup',
        ),
      ],
    );
  }
}

class _AdvancedGroupEntry extends StatelessWidget {
  const _AdvancedGroupEntry({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.groupId,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String groupId;

  @override
  Widget build(BuildContext context) {
    return SettingsGroupEntry(
      icon: icon,
      title: title,
      subtitle: subtitle,
      onTap: () => context.push('${app_paths.SETTINGS_GROUP_PAGE}/$groupId'),
    );
  }
}
