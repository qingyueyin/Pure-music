import 'package:flutter/material.dart';

/// 全局菜单样式，避免在多个文件中重复定义
MenuStyle get appMenuStyle => MenuStyle(
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );

ButtonStyle get appMenuItemStyle => ButtonStyle(
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
