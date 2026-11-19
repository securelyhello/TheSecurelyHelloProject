import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

import 'package:securelyhello/core/calls/call_system.dart';
import 'package:securelyhello/core/notifications/notification_actions.dart';
import 'package:securelyhello/core/notifications/push_background.dart';
import 'package:securelyhello/core/stories/story_service.dart';
import 'package:securelyhello/features/contacts/screens/contact_list_screen.dart';
import 'package:securelyhello/core/update/app_updater.dart';
import 'package:securelyhello/features/update/update_widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/calls/call_service.dart';
import 'package:securelyhello/core/invites/invites.dart';
import 'package:securelyhello/core/config/app_config.dart';
import 'package:securelyhello/core/config/release_logging.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/l10n/app_localizations.dart';
import 'package:securelyhello/shared/theme/locale_controller.dart';
import 'package:securelyhello/shared/theme/theme_controller.dart';
import 'package:securelyhello/core/storage/local_storage.dart';
import 'package:securelyhello/core/storage/secure_key_store.dart';
import 'package:securelyhello/core/networking/directory_service.dart';
import 'package:securelyhello/core/networking/p2p_connection_manager.dart';
import 'package:securelyhello/core/networking/tls_pinning.dart';
import 'package:securelyhello/core/chat/chat_service.dart';
import 'package:securelyhello/core/chat/profile_service.dart';
import 'package:securelyhello/core/providers/auth_provider.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/core/providers/chat_provider.dart';
import 'package:securelyhello/core/providers/connection_provider.dart';
import 'package:securelyhello/core/notifications/notification_service.dart';
import 'package:securelyhello/core/notifications/push_service.dart';
import 'package:securelyhello/core/security/app_lock.dart';
import 'package:securelyhello/features/security/lock_screen.dart';
import 'package:securelyhello/features/auth/screens/splash_screen.dart';
import 'package:securelyhello/features/auth/screens/login_screen.dart';
import 'package:securelyhello/features/auth/screens/welcome_screen.dart';
import 'package:securelyhello/features/auth/screens/signup_screen.dart';
import 'package:securelyhello/features/auth/screens/verify_email_screen.dart';
import 'package:securelyhello/features/auth/screens/forgot_password_screen.dart';
import 'package:securelyhello/features/auth/screens/device_pending_screen.dart';
import 'package:securelyhello/features/home/home_screen.dart';
import 'package:securelyhello/features/contacts/screens/add_contact_screen.dart';
import 'package:securelyhello/features/contacts/screens/contact_requests_screen.dart';
import 'package:securelyhello/features/chat/screens/chat_screen.dart';
import 'package:securelyhello/features/settings/screens/linked_devices_screen.dart';

Future<void> main() async {
  // Release builds must not write diagnostics to the system log.
  silenceDebugPrintInRelease();
  WidgetsFlutterBinding.ensureInitialized();

  // Lock to portrait on mobile (optional on desktop/web)
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Load environment variables gracefully
  try {
    await dotenv.load(fileName: '.env');
  } catch (e) {
    debugPrint('Failed to load .env file: $e');
  }

  // Core services. The local database is opened per account after sign-in
  // (see AuthProvider), not here. SH_PROFILE namespaces local state so two
  // instances with different accounts can run side by side.
  final profile = AppConfig.profile;
  final localStorage = LocalStorage(profile: profile);
  final keyStore = SecureKeyStore(namespace: profile);
  final DirectoryService directoryService;
  try {
    directoryService = DirectoryService(
      baseUrl: AppConfig.apiBaseUrl,
      tokenStore: keyStore,
      pinning: TlsPinning.parse(AppConfig.certPins),
    );
  } on ArgumentError catch (e) {
    runApp(_ConfigErrorApp(message: e.message.toString()));
    return;
  }
  final connectionManager = P2PConnectionManager();
  try {
    await connectionManager.init(
      iceServers: AppConfig.iceServers(P2PConnectionManager.defaultStunServers),
    );
  } catch (e) {
    debugPrint('P2P Connection Manager init failed: $e');
  }

  final chatService = ChatService(
    storage: localStorage,
    directory: directoryService,
    p2p: connectionManager,
  );

  final authProvider = AuthProvider(
    directoryService: directoryService,
    localStorage: localStorage,
    keyStore: keyStore,
  );
  final chatProvider = ChatProvider(chatService: chatService);
  final contactsProvider = ContactsProvider(
    directoryService: directoryService,
    localStorage: localStorage,
  );
  await DeviceCallMedia.loadSettings();
  final calls = CallService(
    chat: chatService,
    canCall: (userId) => contactsProvider.getContact(userId) != null,
  );
  // 1.1 gets data-only pushes: decrypt and notify (or ring) in the background.
  if (PushService.configured) FirebaseMessaging.onBackgroundMessage(pushBackgroundHandler);
  final notifications = NotificationService();
  await notifications.init(backgroundHandler: notificationBackgroundHandler);
  // Calls ring like a phone and keep going in the background (Android).
  final callSystem = CallSystemHolder(
    calls,
    nameOf: (peer) => contactsProvider.getContact(peer)?.displayLabel ?? 'Securely Hello',
    notifier: notifications,
  );
  final push = PushService(directory: directoryService, onWake: chatService.drainRelayQueue);
  final connectionProvider = ConnectionProvider(
    connectionManager: connectionManager,
    chatService: chatService,
  )..init();

  final stories = StoryService(chat: chatService, directory: directoryService, storage: localStorage);

  // Tear down per-user state before the session and database go away.
  authProvider
    ..addSignOutHook(push.stop)
    ..addSignOutHook(() async => stories.stop())
    ..addSignOutHook(calls.hangUp)
    ..addSignOutHook(chatProvider.reset)
    ..addSignOutHook(contactsProvider.reset)
    ..addSignOutHook(() async => connectionProvider.reset());
  final theme = ThemeController();
  await theme.load();
  final language = LocaleController();
  await language.load();
  final appLock = AppLockService(store: keyStore)..onWipe = authProvider.wipeThisDevice;
  await appLock.init();
  unawaited(appLock.resumePendingWipe());
  final invites = PendingInvites();
  unawaited(invites.init());
  // APK builds: look for an update now (then at most every 12 hours), and
  // ask the server whether this build is still supported.
  final updater = AppUpdater();
  if (updater.enabled) {
    unawaited(updater.check());
    unawaited(_applyServerMinimum(directoryService, updater));
  }
  unawaited(authProvider.init());

  runApp(
    SecurelyHelloApp(
      authProvider: authProvider,
      chatProvider: chatProvider,
      contactsProvider: contactsProvider,
      connectionProvider: connectionProvider,
      notifications: notifications,
      push: push,
      appLock: appLock,
      invites: invites,
      profiles: chatService.profiles,
      calls: calls,
      theme: theme,
      language: language,
      updater: updater,
      callSystem: callSystem,
      stories: stories,
    ),
  );
}

Future<void> _applyServerMinimum(DirectoryService directory, AppUpdater updater) async {
  try {
    final min = (await directory.getServerConfig())['min_android_version_code'];
    if (min is int) updater.serverMinimum = min;
  } catch (e) {
    debugPrint('Server config unavailable: $e');
  }
}

/// Shown instead of the app when it was built without a server address.
class _ConfigErrorApp extends StatelessWidget {
  final String message;
  const _ConfigErrorApp({required this.message});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              'Securely Hello is not configured.\n\n$message',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}

class SecurelyHelloApp extends StatelessWidget {
  final AuthProvider authProvider;
  final ChatProvider chatProvider;
  final ContactsProvider contactsProvider;
  final ConnectionProvider connectionProvider;
  final NotificationService? notifications;
  final PushService? push;
  final AppLockService? appLock;
  final PendingInvites? invites;
  final ProfileService? profiles;
  final CallService? calls;
  final ThemeController theme;
  final LocaleController language;
  final AppUpdater? updater;
  final CallSystemHolder? callSystem;
  final StoryService? stories;

  SecurelyHelloApp({
    super.key,
    required this.authProvider,
    required this.chatProvider,
    required this.contactsProvider,
    required this.connectionProvider,
    this.notifications,
    this.push,
    this.appLock,
    this.invites,
    this.profiles,
    this.calls,
    this.updater,
    this.callSystem,
    this.stories,
    ThemeController? theme,
    LocaleController? language,
  })  : theme = theme ?? ThemeController(),
        language = language ?? LocaleController();

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: authProvider),
        ChangeNotifierProvider.value(value: contactsProvider),
        ChangeNotifierProvider.value(value: chatProvider),
        ChangeNotifierProvider.value(value: connectionProvider),
        Provider<NotificationService>.value(value: notifications ?? NotificationService()),
        Provider<PushService?>.value(value: push),
        ChangeNotifierProvider<PendingInvites?>.value(value: invites),
        ChangeNotifierProvider<CallService?>.value(value: calls),
        ChangeNotifierProvider<AppUpdater?>.value(value: updater),
        Provider<CallSystemHolder?>.value(value: callSystem),
        ChangeNotifierProvider<StoryService?>.value(value: stories),
        ChangeNotifierProvider<ThemeController>.value(value: theme),
        ChangeNotifierProvider<LocaleController>.value(value: language),
        if (profiles != null) ChangeNotifierProvider<ProfileService>.value(value: profiles!),
        ChangeNotifierProvider<AppLockService>.value(
          value: appLock ?? AppLockService(store: SecureKeyStore(storage: MemorySecretStorage())),
        ),
      ],
      // Listens to the controller itself: this context is above the providers.
      child: ListenableBuilder(
        listenable: Listenable.merge([theme, language]),
        builder: (context, _) => MaterialApp(
          title: 'Securely Hello',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: theme.mode,
          locale: language.locale,
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          builder: (context, child) => UpdateGate(child: AppLockGate(child: child ?? const SizedBox())),
          initialRoute: '/splash',
          routes: {
            '/splash': (context) => const SplashScreen(),
            '/welcome': (context) => const WelcomeScreen(),
            '/login': (context) => const LoginScreen(),
            '/signup': (context) => const SignupScreen(),
            '/verify-email': (context) => const VerifyEmailScreen(),
            '/device-pending': (context) => const DevicePendingScreen(),
            '/home': (context) => const HomeScreen(),
            '/add-contact': (context) => const AddContactScreen(),
            '/contact-requests': (context) => const ContactRequestsScreen(),
            '/people': (context) => const ContactListScreen(),
            '/devices': (context) => const LinkedDevicesScreen(),
          },
          onGenerateRoute: (settings) {
            // Handle routes with arguments
            if (settings.name == '/forgot-password') {
              return MaterialPageRoute(
                builder: (context) =>
                    ForgotPasswordScreen(initialEmail: settings.arguments as String?),
                settings: settings,
              );
            }
            if (settings.name == '/chat') {
              final contactUserId = settings.arguments as String;
              return MaterialPageRoute(
                builder: (context) => ChatScreen(contactUserId: contactUserId),
                settings: settings,
              );
            }
            return null;
          },
        ),
      ),
    );
  }
}
