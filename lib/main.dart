import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/config/app_config.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/core/storage/local_storage.dart';
import 'package:securelyhello/core/storage/secure_key_store.dart';
import 'package:securelyhello/core/networking/directory_service.dart';
import 'package:securelyhello/core/networking/p2p_connection_manager.dart';
import 'package:securelyhello/core/chat/chat_service.dart';
import 'package:securelyhello/core/providers/auth_provider.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/core/providers/chat_provider.dart';
import 'package:securelyhello/core/providers/connection_provider.dart';
import 'package:securelyhello/features/auth/screens/splash_screen.dart';
import 'package:securelyhello/features/auth/screens/login_screen.dart';
import 'package:securelyhello/features/auth/screens/signup_screen.dart';
import 'package:securelyhello/features/home/home_screen.dart';
import 'package:securelyhello/features/contacts/screens/add_contact_screen.dart';
import 'package:securelyhello/features/contacts/screens/contact_requests_screen.dart';
import 'package:securelyhello/features/chat/screens/chat_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock to portrait on mobile (optional on desktop/web)
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Set system UI overlay style for dark theme
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF0A0A0F),
    systemNavigationBarIconBrightness: Brightness.light,
  ));

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
        baseUrl: AppConfig.apiBaseUrl, tokenStore: keyStore);
  } on ArgumentError catch (e) {
    runApp(_ConfigErrorApp(message: e.message.toString()));
    return;
  }
  final connectionManager = P2PConnectionManager();
  try {
    await connectionManager.init(
        iceServers:
            AppConfig.iceServers(P2PConnectionManager.defaultStunServers));
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
    chatService: chatService,
  );
  final connectionProvider = ConnectionProvider(
    connectionManager: connectionManager,
    chatService: chatService,
  )..init();

  // Tear down per-user state before the session and database go away.
  authProvider
    ..addSignOutHook(chatProvider.reset)
    ..addSignOutHook(contactsProvider.reset)
    ..addSignOutHook(() async => connectionProvider.reset());
  unawaited(authProvider.init());

  runApp(SecurelyHelloApp(
    authProvider: authProvider,
    chatProvider: chatProvider,
    contactsProvider: contactsProvider,
    connectionProvider: connectionProvider,
  ));
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

  const SecurelyHelloApp({
    super.key,
    required this.authProvider,
    required this.chatProvider,
    required this.contactsProvider,
    required this.connectionProvider,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: authProvider),
        ChangeNotifierProvider.value(value: contactsProvider),
        ChangeNotifierProvider.value(value: chatProvider),
        ChangeNotifierProvider.value(value: connectionProvider),
      ],
      child: MaterialApp(
        title: 'Securely Hello',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark,
        initialRoute: '/splash',
        routes: {
          '/splash': (context) => const SplashScreen(),
          '/login': (context) => const LoginScreen(),
          '/signup': (context) => const SignupScreen(),
          '/home': (context) => const HomeScreen(),
          '/add-contact': (context) => const AddContactScreen(),
          '/contact-requests': (context) => const ContactRequestsScreen(),
        },
        onGenerateRoute: (settings) {
          // Handle routes with arguments
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
    );
  }
}
