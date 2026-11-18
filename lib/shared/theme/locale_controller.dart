import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The app's language: the system's (default) or one the user picked.
class LocaleController extends ChangeNotifier {
  static const _key = 'sh_locale';

  /// Languages with translations (lib/l10n/app_*.arb), by code.
  static const names = {'en': 'English', 'hi': 'हिन्दी'};

  Locale? _locale;

  /// null: follow the system.
  Locale? get locale => _locale;

  Future<void> load() async {
    try {
      final code = (await SharedPreferences.getInstance()).getString(_key);
      _locale = names.containsKey(code) ? Locale(code!) : null;
    } catch (_) {
      _locale = null;
    }
    notifyListeners();
  }

  Future<void> set(Locale? locale) async {
    _locale = locale;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (locale == null) {
        await prefs.remove(_key);
      } else {
        await prefs.setString(_key, locale.languageCode);
      }
    } catch (_) {}
  }
}
