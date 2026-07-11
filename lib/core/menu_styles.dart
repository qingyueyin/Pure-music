import 'package:flutter/material.dart';
import 'package:pure_music/core/design_tokens.dart';

/// 全局菜单样式，避免在多个文件中重复定义
MenuStyle get appMenuStyle => MenuStyle(
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: AppRadius.mdCircular),
      ),
    );

ButtonStyle get appMenuItemStyle => ButtonStyle(
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: AppRadius.mdCircular),
      ),
    );
