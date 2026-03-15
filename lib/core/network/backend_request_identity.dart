import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class BackendRequestIdentity {
  static const _prefsKey = 'backend_device_id';
  static const Uuid _uuid = Uuid();

  static String? _cachedDeviceId;
  static Future<String>? _deviceIdFuture;

  static Future<String> get deviceId async {
    final cached = _cachedDeviceId;
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }

    final inFlight = _deviceIdFuture;
    if (inFlight != null) {
      return inFlight;
    }

    final future = _loadOrCreateDeviceId();
    _deviceIdFuture = future;
    return future;
  }

  static Future<String> _loadOrCreateDeviceId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefsKey);
      if (saved != null && saved.isNotEmpty) {
        _cachedDeviceId = saved;
        return saved;
      }

      final created = _uuid.v4();
      await prefs.setString(_prefsKey, created);
      _cachedDeviceId = created;
      return created;
    } finally {
      _deviceIdFuture = null;
    }
  }
}
