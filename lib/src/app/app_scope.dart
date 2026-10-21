import 'package:flutter/widgets.dart';

import 'app_controller.dart';

/// Makes the [AppController] available to the whole widget tree.
///
/// An [InheritedNotifier] rather than a package: the app has exactly one
/// long-lived controller, and rebuilding dependents when it notifies is the
/// entire requirement. Adding a dependency-injection framework for one object
/// would be more machinery than the problem deserves.
class AppScope extends InheritedNotifier<AppController> {
  const AppScope({
    required AppController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  /// The controller, subscribing the calling widget to its notifications.
  static AppController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope.of() was called outside of an AppScope.');
    return scope!.notifier!;
  }

  /// The controller without subscribing, for callbacks and one-off reads.
  static AppController read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope.read() was called outside of an AppScope.');
    return scope!.notifier!;
  }

  /// The controller if one is in scope, otherwise null. Used by previews and
  /// by widgets that also work standalone.
  static AppController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()?.notifier;
}
