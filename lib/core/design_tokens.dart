import 'package:flutter/material.dart';

abstract final class Spacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double bottomNav = 96;
}

abstract final class AppRadius {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;

  static BorderRadius get xsCircular => BorderRadius.circular(xs);
  static BorderRadius get smCircular => BorderRadius.circular(sm);
  static BorderRadius get mdCircular => BorderRadius.circular(md);
}

abstract final class AppType {
  static const double microlabel = 10;
  static const double caption = 12;
  static const double body = 14;
  static const double subtitle = 16;
  static const double sectionTitle = 18;
  static const double pageTitle = 20;
  static const double hero = 24;
  static const double display = 32;

  static const FontWeight weightRegular = FontWeight.w400;
  static const FontWeight weightMedium = FontWeight.w500;
  static const FontWeight weightSemibold = FontWeight.w600;
  static const FontWeight weightBold = FontWeight.w700;
}

abstract final class Alpha {
  static const double hover = 0.04;
  static const double focus = 0.04;
}
