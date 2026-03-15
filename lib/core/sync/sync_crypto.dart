import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:pointycastle/export.dart';

/// 加密工具 (AES-256-GCM + PBKDF2)
class SyncCrypto {
  // 10w次迭代平衡性能安全
  static const int _pbkdf2Iterations = 100000;
  static const int _keyLength = 32; // AES-256
  static const int _saltLength = 16;
  static const int _ivLength = 12;

  /// 生成强密码 (32字节随机)
  static String generateSecurePassword() {
    final random = Random.secure();
    final bytes = Uint8List.fromList(
      List.generate(32, (_) => random.nextInt(256)),
    );
    return base64Encode(bytes);
  }

  /// 校验密码 (8-32位，大小写+数字)
  static bool isValidPassword(String password) {
    if (password.length < 8 || password.length > 50) return false;

    // 自动生成的强密码直接通过
    if (password.length >= 32) return true;

    final hasLowerCase = RegExp(r'[a-z]').hasMatch(password);
    final hasUpperCase = RegExp(r'[A-Z]').hasMatch(password);
    final hasDigit = RegExp(r'[0-9]').hasMatch(password);

    return hasLowerCase && hasUpperCase && hasDigit;
  }

  /// 复用 Key 加密 (AES-GCM)
  static String encryptWithKey(
    String plainText,
    Uint8List key,
    Uint8List salt,
  ) {
    // 随机 IV
    final iv = Uint8List.fromList(
      List.generate(_ivLength, (_) => random.nextInt(256)),
    );

    final cipher = GCMBlockCipher(AESEngine())..init(
      true, // encrypt
      AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)),
    );

    final plainBytes = utf8.encode(plainText);
    final cipherBytes = cipher.process(Uint8List.fromList(plainBytes));

    return jsonEncode({
      'v': 1,
      'salt': base64Encode(salt),
      'iv': base64Encode(iv),
      'data': base64Encode(cipherBytes),
    });
  }

  /// 完整加密 (含 Key 派生)
  static String encrypt(String plainText, String password) {
    // 随机 Salt
    final salt = Uint8List.fromList(
      List.generate(_saltLength, (_) => random.nextInt(256)),
    );

    final key = _deriveKey(password, salt, _pbkdf2Iterations);
    return encryptWithKey(plainText, key, salt);
  }

  /// 解密 (AES-GCM)
  static String decrypt(String encryptedJson, String password) {
    final json = jsonDecode(encryptedJson) as Map<String, dynamic>;

    if (json['v'] != 1) throw Exception('版本不支持');

    // 兼容: 优先读取 JSON 中的 iter，缺失则用默认 10w
    final iterations = json['iter'] as int? ?? _pbkdf2Iterations;

    final salt = base64Decode(json['salt'] as String);
    final iv = base64Decode(json['iv'] as String);
    final cipherBytes = base64Decode(json['data'] as String);

    final key = _deriveKey(password, Uint8List.fromList(salt), iterations);

    final cipher = GCMBlockCipher(AESEngine())..init(
      false, // decrypt
      AEADParameters(
        KeyParameter(key),
        128,
        Uint8List.fromList(iv),
        Uint8List(0),
      ),
    );

    try {
      final plainBytes = cipher.process(Uint8List.fromList(cipherBytes));
      return utf8.decode(plainBytes);
    } catch (e) {
      throw Exception('密码错误或解密失败');
    }
  }

  /// PBKDF2 派生 Key
  static Uint8List _deriveKey(String password, Uint8List salt, int iterations) {
    final pbkdf2 = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, iterations, _keyLength));
    return pbkdf2.process(Uint8List.fromList(utf8.encode(password)));
  }
}

final random = Random.secure();

/// Isolate 专用：后台派生 Key
Future<Uint8List> deriveKeyCompute(Map<String, dynamic> params) async {
  final pbkdf2 = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(params['salt'], params['iter'], 32));
  return pbkdf2.process(Uint8List.fromList(utf8.encode(params['pass'])));
}
