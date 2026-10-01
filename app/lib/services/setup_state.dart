import 'package:shared_preferences/shared_preferences.dart';

class SetupState {
  static const String _setupCompleteKey = 'lumin_setup_complete';
  static const String _userNameKey = 'lumin_user_name';
  static const String _userEmailKey = 'lumin_user_email';
  static const String _emergencyContactKey = 'lumin_emergency_contact';

  static Future<bool> isComplete() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_setupCompleteKey) ?? false;
  }

  static Future<void> markComplete() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_setupCompleteKey, true);
  }

  static Future<UserProfile> loadProfile() async {
    final prefs = await SharedPreferences.getInstance();
    return UserProfile(
      name: prefs.getString(_userNameKey) ?? '',
      email: prefs.getString(_userEmailKey) ?? '',
      emergencyContact: prefs.getString(_emergencyContactKey) ?? '',
    );
  }

  static Future<void> saveProfile(UserProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userNameKey, profile.name.trim());
    await prefs.setString(_userEmailKey, profile.email.trim());
    await prefs.setString(
      _emergencyContactKey,
      profile.emergencyContact.trim(),
    );
  }

  static Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_setupCompleteKey);
    await prefs.remove(_userNameKey);
    await prefs.remove(_userEmailKey);
    await prefs.remove(_emergencyContactKey);
  }
}

class UserProfile {
  const UserProfile({
    required this.name,
    required this.email,
    required this.emergencyContact,
  });

  final String name;
  final String email;
  final String emergencyContact;
}
