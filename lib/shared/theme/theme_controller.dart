import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Light, dark, or follow the system (default). Remembered on this device.
class ThemeController extends ChangeNotifier {
  static const _key = 'sh_theme_mode';
  ThemeMode _mode = ThemeMode.system;

  ThemeMode get mode => _mode;

  Future<void> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      _mode = ThemeMode.values.firstWhere((m) => m.name == raw, orElse: () => ThemeMode.system);
    } catch (_) {
      _mode = ThemeMode.system;
    }
    notifyListeners();
  }

  Future<void> set(ThemeMode mode) async {
    _mode = mode;
    notifyListeners();
    try {
      await (await SharedPreferences.getInstance()).setString(_key, mode.name);
    } catch (_) {}
  }

  static String label(ThemeMode m) => switch (m) {
        ThemeMode.system => 'Same as the system',
        ThemeMode.light => 'Light',
        ThemeMode.dark => 'Dark',
      };
}
