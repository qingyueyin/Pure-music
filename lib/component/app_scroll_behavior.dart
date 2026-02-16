import 'package:flutter/material.dart';

class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return RawScrollbar(
      controller: details.controller,
      interactive: true,
      thickness: 10,
      radius: const Radius.circular(999),
      mainAxisMargin: 4,
      crossAxisMargin: 4,
      child: child,
    );
  }
}
