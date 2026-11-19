// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class L10nEn extends L10n {
  L10nEn([String locale = 'en']) : super(locale);

  @override
  String get welcomeSkip => 'Skip';

  @override
  String get welcomeNext => 'Next';

  @override
  String get welcome1Title => 'Only you and them';

  @override
  String get welcome1Body =>
      'Every message, photo, file and voice note is encrypted on your phone. Only the people you\'re talking to can open it. Not us, not the server.';

  @override
  String get welcome2Title => 'Know who you\'re talking to';

  @override
  String get welcome2Body =>
      'Compare a safety number or scan a code to be sure. If someone\'s keys ever change, the app tells you before sending anything.';

  @override
  String get welcome3Title => 'Only people you choose';

  @override
  String get welcome3Body =>
      'Strangers need your OK before they can message you. No phone number needed, no ads, no tracking.';

  @override
  String get welcomeCreateAccount => 'Create an account';

  @override
  String get welcomeHaveAccount => 'I already have an account';

  @override
  String get loginTitle => 'Welcome back';

  @override
  String get email => 'Email';

  @override
  String get emailHint => 'Enter your email';

  @override
  String get emailRequired => 'Email is required';

  @override
  String get password => 'Password';

  @override
  String get passwordHint => 'Enter your password';

  @override
  String get passwordRequired => 'Password is required';

  @override
  String get forgotPassword => 'Forgot password?';

  @override
  String get logIn => 'Log in';

  @override
  String get noAccount => 'Don\'t have an account?';

  @override
  String get signUp => 'Sign up';

  @override
  String get signupTitle => 'Create your account';

  @override
  String get signupSubtitle => 'Join Securely Hello and chat privately.';

  @override
  String get emailInvalid => 'Valid email required';

  @override
  String get displayName => 'Display Name';

  @override
  String get displayNameHint => 'How others will see you';

  @override
  String get displayNameRequired => 'Display name is required';

  @override
  String get username => 'Username';

  @override
  String get usernameTooShort => 'Min 3 characters';

  @override
  String get usernameRules => 'Letters, numbers and _ only (max 30)';

  @override
  String get usernameTaken => 'Username is taken';

  @override
  String get passwordCreateHint => 'Create a strong password';

  @override
  String get passwordTooShort => 'At least 8 characters';

  @override
  String get confirmPassword => 'Confirm Password';

  @override
  String get confirmPasswordHint => 'Repeat your password';

  @override
  String get passwordsDontMatch => 'Passwords do not match';

  @override
  String get agreePrefix => 'By signing up you agree to the ';

  @override
  String get terms => 'Terms';

  @override
  String get privacyPolicy => 'Privacy policy';

  @override
  String get haveAccount => 'Already have an account?';

  @override
  String get tabChats => 'Chats';

  @override
  String get tabContacts => 'Contacts';

  @override
  String get tabCalls => 'Calls';

  @override
  String get tabSettings => 'Settings';

  @override
  String get e2eNote => 'Your messages are end-to-end encrypted';

  @override
  String get messageHint => 'Message';

  @override
  String get attachFile => 'Attach a file';

  @override
  String get recordVoice => 'Record a voice message';

  @override
  String get micPermission =>
      'Allow microphone access to record voice messages';

  @override
  String get send => 'Send';

  @override
  String get lockTitle => 'Securely Hello is locked';

  @override
  String get pin => 'PIN';

  @override
  String get unlock => 'Unlock';

  @override
  String get useBiometrics => 'Use biometrics';

  @override
  String get wrongPin => 'Wrong PIN';

  @override
  String get settingsAppearance => 'Appearance';

  @override
  String get settingsTheme => 'Theme';

  @override
  String get themeSystem => 'Same as the system';

  @override
  String get themeLight => 'Light';

  @override
  String get themeDark => 'Dark';

  @override
  String get settingsLanguage => 'Language';

  @override
  String get languageSystem => 'Same as the system';

  @override
  String get settingsNotifications => 'Notifications';

  @override
  String get settingsPrivacy => 'Privacy & security';

  @override
  String get settingsAppLock => 'App lock';

  @override
  String get settingsAccount => 'Account';

  @override
  String get settingsAbout => 'About';

  @override
  String get cancel => 'Cancel';

  @override
  String get save => 'Save';

  @override
  String wrongPinLeft(int left) {
    return 'Wrong PIN. $left more and this device is erased.';
  }

  @override
  String waitSeconds(int seconds) {
    return 'Too many tries. Wait $seconds s';
  }

  @override
  String get searchChats => 'Search chats';

  @override
  String get filterAll => 'All';

  @override
  String get filterUnread => 'Unread';

  @override
  String filterUnreadCount(int count) {
    return 'Unread ($count)';
  }

  @override
  String get contactRequests => 'Contact requests';

  @override
  String contactRequestsCount(int count) {
    return 'Contact requests ($count)';
  }

  @override
  String get noUnreadChats => 'No unread chats.';

  @override
  String get moreOptions => 'More options';

  @override
  String get findPeople => 'Find people';

  @override
  String get newChat => 'New chat';

  @override
  String get markAsRead => 'Mark as read';

  @override
  String get contactInfo => 'Contact info';

  @override
  String get clearChatHistory => 'Clear chat history';

  @override
  String get deleteChat => 'Delete chat';

  @override
  String get searchContacts => 'Search contacts';

  @override
  String get searchByUsername => 'Search by username';

  @override
  String get noPendingRequests => 'No pending requests';

  @override
  String onlineCount(int count) {
    return 'Online — $count';
  }

  @override
  String offlineCount(int count) {
    return 'Offline — $count';
  }

  @override
  String contactsCount(int count) {
    return 'Contacts — $count';
  }

  @override
  String get removeContact => 'Remove contact';

  @override
  String get message => 'Message';

  @override
  String get emptyContactsTitle => 'No contacts yet';

  @override
  String get emptyContactsBody =>
      'Find people by their username and send them a contact request. Once they accept, you can chat securely.';

  @override
  String get emptyChatsTitle => 'No chats yet';

  @override
  String get emptyChatsBody =>
      'Start a conversation with one of your contacts. Messages are end-to-end encrypted.';

  @override
  String get startChat => 'Start a chat';

  @override
  String get noResults => 'No results';

  @override
  String get tryDifferentSearch => 'Try a different search term.';

  @override
  String nothingMatches(String query) {
    return 'Nothing matches “$query”. Check the spelling or try another term.';
  }

  @override
  String get somethingWentWrong => 'Something went wrong';

  @override
  String get tryAgain => 'Try again';
}
