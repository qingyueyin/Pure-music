import 'package:flutter/material.dart';

class MotionDuration {
  static const xFast = Duration(milliseconds: 120);
  static const fast = Duration(milliseconds: 180);
  static const base = Duration(milliseconds: 280);
  static const medium = Duration(milliseconds: 360);
  static const slow = Duration(milliseconds: 420);
  static const xSlow = Duration(milliseconds: 560);
}

class MotionCurve {
  static const standard = Curves.fastOutSlowIn;
  static const emphasized = Curves.easeInOutCubic;
}
