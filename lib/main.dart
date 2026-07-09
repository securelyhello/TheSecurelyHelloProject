import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide LocalStorage;

import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/core/storage/local_storage.dart';
import 'package:securelyhello/core/networking/supabase_directory_service.dart';
import 'package:securelyhello/core/networking/p2p_connection_manager.dart';
import 'package:securelyhello/core/chat/chat_service.dart';
import 'package:securelyhello/core/providers/auth_provider.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/core/providers/chat_provider.dart';
import 'package:securelyhello/core/providers/connection_provider.dart';
import 'package:securelyhello/features/auth/screens/splash_screen.dart';
import 'package:securelyhello/features/auth/screens/login_screen.dart';
import 'package:securelyhello/features/auth/screens/signup_screen.dart';
import 'package:securelyhello/features/auth/screens/verify_email_screen.dart';
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

  // Initialize Supabase gracefully
  try {
    await Supabase.initialize(
      url: dotenv.env['SUPABASE_URL'] ?? '',
      publishableKey: dotenv.env['SUPABASE_ANON_KEY'] ?? '',
    );
  } catch (e) {
    debugPrint('Supabase init failed: $e');
  }

  // Initialize core services
  final localStorage = LocalStorage();
  try {
    await localStorage.init();
  } catch (e) {
    debugPrint('LocalStorage init failed: $e');
  }

  final directoryService = SupabaseDirectoryService();
  final connectionManager = P2PConnectionManager();
  try {
    await connectionManager.init();
  } catch (e) {
    debugPrint('P2P Connection Manager init failed: $e');
  }

  final chatService = ChatService(
    storage: localStorage,
    directory: directoryService,
    p2p: connectionManager,
  );

  runApp(SecurelyHelloApp(
    localStorage: localStorage,
    directoryService: directoryService,
    connectionManager: connectionManager,
    chatService: chatService,
  ));
}

class SecurelyHelloApp extends StatelessWidget {
  final LocalStorage localStorage;
  final SupabaseDirectoryService directoryService;
  final P2PConnectionManager connectionManager;
  final ChatService chatService;

  const SecurelyHelloApp({
    super.key,
    required this.localStorage,
    required this.directoryService,
    required this.connectionManager,
    required this.chatService,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => AuthProvider(
            directoryService: directoryService,
            localStorage: localStorage,
          )..init(),
        ),
        ChangeNotifierProvider(
          create: (_) => ContactsProvider(
            directoryService: directoryService,
            localStorage: localStorage,
          )..init(),
        ),
        ChangeNotifierProvider(
          create: (_) => ChatProvider(
            chatService: chatService,
            localStorage: localStorage,
          ),
        ),
        ChangeNotifierProvider(
          create: (_) => ConnectionProvider(
            connectionManager: connectionManager,
          )..init(),
        ),
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
          '/verify-email': (context) => const VerifyEmailScreen(),
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
