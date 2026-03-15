import 'dart:async';
import 'dart:convert';
import 'dart:math'; // for Random
import 'package:flutter/foundation.dart'; // for compute + listEquals
import 'package:flutter/widgets.dart'; // for WidgetsBindingObserver
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logging/logging.dart';
import 'package:novella/core/sync/gist_sync_service.dart';
import 'package:novella/core/sync/webdav_sync_service.dart';
import 'package:novella/core/sync/sync_crypto.dart';
import 'package:novella/core/sync/sync_data_model.dart';
import 'package:novella/data/services/book_mark_service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 同步状态
enum SyncStatus {
  disconnected, // 未连接
  idle, // 空闲
  syncing, // 同步中
  error, // 出错
}

/// 同步管理器
class SyncManager with ChangeNotifier, WidgetsBindingObserver {
  static final Logger _logger = Logger('SyncManager');
  static final SyncManager _instance = SyncManager._internal();

  factory SyncManager() => _instance;
  SyncManager._internal() {
    WidgetsBinding.instance.addObserver(this);
  }

  final GistSyncService _gistService = GistSyncService();
  final WebDavSyncService _webdavService = WebDavSyncService();
  final BookMarkService _bookMarkService = BookMarkService();

  static const _storage = FlutterSecureStorage();
  static const _keyGithubToken = 'github_access_token';
  static const _keyGistId = 'sync_gist_id';
  static const _keySyncPassword = 'sync_password';
  static const _keyLastSyncTime = 'last_sync_time';
  static const _keyLastSyncId = 'last_sync_id';

  // ==================== WebDAV 配置持久化 Key ====================
  static const _keyUseWebDav = 'use_webdav';
  static const _keyWebDavHost = 'webdav_host';
  static const _keyWebDavUser = 'webdav_user';
  static const _keyWebDavPass = 'webdav_password'; // SecureStorage

  bool useWebDav = false;

  SyncStatus _status = SyncStatus.disconnected;
  DateTime? _lastSyncTime;
  String? _errorMessage;
  bool _isSyncing = false; 

  // 缓存 Key
  Uint8List? _cachedKey;
  Uint8List? _cachedSalt;
  String? _lastKnownSyncId;

  Timer? _syncDebounceTimer;
  static const _syncDebounceDelay = Duration(seconds: 20);

  // 自动重试
  int _retryCount = 0;
  static const _maxRetries = 3;
  DateTime? _lastFailureTime;

  int _pendingSyncCount = 0;
  static const _maxPendingBeforeDrop = 2;

  /// 检查后端是否已连接
  bool get _currentConnected => useWebDav ? _webdavService.isConnected : _gistService.isConnected;

  SyncStatus get status => _status;
  DateTime? get lastSyncTime => _lastSyncTime;
  String? get errorMessage => _errorMessage;
  bool get isConnected => _gistService.isConnected || _webdavService.isConnected;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      Future.delayed(const Duration(milliseconds: 500), () {
        triggerSync(immediate: true);
      });
    }
  }

  /// 初始化
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final lastSyncStr = prefs.getString(_keyLastSyncTime);
    _lastKnownSyncId = prefs.getString(_keyLastSyncId);

    if (lastSyncStr != null) {
      _lastSyncTime = DateTime.tryParse(lastSyncStr);
    }

    // 从本地读取是否启用 WebDAV
    useWebDav = prefs.getBool(_keyUseWebDav) ?? false;

    if (useWebDav) {
      // 读取 WebDAV 配置并初始化
      final host = prefs.getString(_keyWebDavHost);
      final user = prefs.getString(_keyWebDavUser);
      final pass = await _storage.read(key: _keyWebDavPass);

      if (host != null && user != null && pass != null) {
        _webdavService.init(host, user, pass);
        _status = SyncStatus.idle;
        _logger.info('Sync manager initialized, connected to WebDAV');
      } else {
        _status = SyncStatus.disconnected;
        _logger.info('Sync manager initialized, WebDAV config missing');
      }
      notifyListeners();
    } else {
      final token = await _storage.read(key: _keyGithubToken);
      final gistId = await _storage.read(key: _keyGistId);

      if (token != null) {
        _gistService.setAccessToken(token, gistId: gistId);
        _status = SyncStatus.idle;
        _logger.info('Sync manager initialized, connected to GitHub');
      } else {
        _status = SyncStatus.disconnected;
        _logger.info('Sync manager initialized, not connected');
      }
      notifyListeners();
    }
  }

  /// 配置并连接 WebDAV
  Future<void> configureWebDav(String host, String user, String password) async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setBool(_keyUseWebDav, true);
    await prefs.setString(_keyWebDavHost, host);
    await prefs.setString(_keyWebDavUser, user);
    await _storage.write(key: _keyWebDavPass, value: password);

    useWebDav = true;
    _webdavService.init(host, user, password);

    _status = SyncStatus.idle;
    notifyListeners();
    _logger.info('WebDAV configured and connected');
  }

  /// 切换回 GitHub 
  Future<void> switchToGitHub() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyUseWebDav, false);
    useWebDav = false;

    await init(); // 重新加载 GitHub 状态
  }

  /// 连接 GitHub (Device Flow) —— WebDAV 模式下禁止调用
  Future<DeviceFlowResponse> startDeviceFlow() async {
    if (useWebDav) {
      throw Exception('WebDAV 模式不支持 GitHub Device Flow 授权');
    }
    return await _gistService.requestDeviceCode();
  }

  /// 完成授权
  Future<bool> completeDeviceFlow(
    DeviceFlowResponse flowData, {
    void Function(int remainingSeconds)? onTick,
  }) async {
    if (useWebDav) {
      throw Exception('WebDAV 模式不支持 GitHub Device Flow 授权');
    }
    final token = await _gistService.pollForToken(flowData, onTick: onTick);
    if (token == null) return false;

    await _storage.write(key: _keyGithubToken, value: token);
    _status = SyncStatus.idle;
    notifyListeners();
    _logger.info('Device flow completed, connected to GitHub');
    return true;
  }

  /// 设置密码 (首次)
  Future<void> setSyncPassword(String password) async {
    if (!SyncCrypto.isValidPassword(password)) {
      throw Exception('密码需包含大小写字母和数字，8-32位');
    }
    await _storage.write(key: _keySyncPassword, value: password);
    _cachedKey = null;
    _cachedSalt = null;
    _logger.info('Sync password set');
  }

  /// 获取密码
  Future<String?> getSyncPassword() async {
    return await _storage.read(key: _keySyncPassword);
  }

  /// 断开连接（同时清理 WebDAV 配置）
  Future<void> disconnect() async {
    final prefs = await SharedPreferences.getInstance();
    if (useWebDav) {
      await _webdavService.disconnect();
      await prefs.setBool(_keyUseWebDav, false);
      await prefs.remove(_keyWebDavHost);
      await prefs.remove(_keyWebDavUser);
      await _storage.delete(key: _keyWebDavPass);
      useWebDav = false;
      _status = SyncStatus.disconnected;
      _cachedKey = null;
      _cachedSalt = null;
      notifyListeners();
      _logger.info('Disconnected from WebDAV and cleared config');
    } else {
      await _storage.delete(key: _keyGithubToken);
      await _storage.delete(key: _keyGistId);
      _gistService.disconnect();
      _status = SyncStatus.disconnected;
      _cachedKey = null;
      _cachedSalt = null;
      notifyListeners();
      _logger.info('Disconnected from GitHub');
    }
  }

  /// 手动同步
  Future<void> sync() async {
    final password = await getSyncPassword();
    if (password == null) {
      throw Exception('请先设置同步密码');
    }
    _retryCount = 0;
    _lastFailureTime = null;
    await _performSync(password);
  }

  /// 触发同步
  void triggerSync({bool immediate = false}) {
    if (!_currentConnected) return;

    if (_shouldResetRetryCount()) {
      _retryCount = 0;
      _lastFailureTime = null;
    }

    _syncDebounceTimer?.cancel();

    if (_isSyncing) {
      _pendingSyncCount++;
      return;
    }

    if (immediate) {
      _runSyncTask();
      return;
    }

    _syncDebounceTimer = Timer(_syncDebounceDelay, _runSyncTask);
  }

  bool _shouldResetRetryCount() {
    if (_lastFailureTime == null) return true;
    final elapsed = DateTime.now().difference(_lastFailureTime!);
    return elapsed.inMinutes >= 5;
  }

  Future<void> _runSyncTask() async {
    final password = await getSyncPassword();
    if (password != null &&
        _status == SyncStatus.idle &&
        _currentConnected &&
        !_isSyncing) {
      try {
        await _performSync(password);
      } catch (e) {
        _logger.warning('Background sync failed: $e');
      }
    }
  }

  /// 下载远程加密数据
  Future<String?> _downloadRemoteEncrypted(String syncRunId) async {
    return useWebDav
        ? await _webdavService.downloadFromWebDav(syncRunId: syncRunId)
        : await _gistService.downloadFromGist(syncRunId: syncRunId);
  }

  /// 上传加密数据
  Future<void> _uploadRemoteEncrypted(String encrypted, String syncRunId) async {
    if (useWebDav) {
      await _webdavService.uploadToWebDav(encrypted, syncRunId: syncRunId);
    } else {
      await _gistService.uploadToGist(encrypted, syncRunId: syncRunId);
    }
  }

  /// 执行同步核心逻辑
  Future<void> _performSync(String password) async {
    if (!_currentConnected) {
      throw Exception('未连接 ${useWebDav ? "WebDAV" : "GitHub"}');
    }

    final syncRunId = DateTime.now().millisecondsSinceEpoch.toString();
    String stage = 'sync_start';

    _isSyncing = true;
    _status = SyncStatus.syncing;
    _errorMessage = null;
    notifyListeners();

    try {
      _logger.info(
        'SYNC run=$syncRunId stage=$stage status_before=$_status lastKnownSyncId=${_lastKnownSyncId ?? "null"} backend=${useWebDav ? "WebDAV" : "GitHub"}',
      );

      stage = 'collect_local';
      final localData = await _collectLocalData();

      stage = 'download';
      final remoteEncrypted = await _downloadRemoteEncrypted(syncRunId);
      SyncData? remoteData;

      if (remoteEncrypted != null) {
        stage = 'decrypt_parse';
        try {
          final decrypted = await compute(_decryptInIsolate, {
            'json': remoteEncrypted,
            'pass': password,
          });
          remoteData = SyncData.fromJson(
            (await _parseJson(decrypted)) as Map<String, dynamic>,
          );

          final encryptedJson = jsonDecode(remoteEncrypted) as Map<String, dynamic>;
          final salt = base64Decode(encryptedJson['salt']);
          final iter = encryptedJson['iter'] as int? ?? 100000;

          if (_cachedKey == null ||
              _cachedSalt == null ||
              !listEquals(_cachedSalt, salt)) {
            _cachedKey = await compute(deriveKeyCompute, {
              'pass': password,
              'salt': salt,
              'iter': iter,
            });
            _cachedSalt = salt;
          }
        } catch (e) {
          _logger.warning('Failed to decrypt remote data: $e');
          rethrow;
        }
      } else {
        if (_cachedKey == null) {
          final random = Random.secure();
          final newSalt = Uint8List.fromList(List.generate(16, (_) => random.nextInt(256)));
          _cachedKey = await compute(deriveKeyCompute, {
            'pass': password,
            'salt': newSalt,
            'iter': 100000,
          });
          _cachedSalt = newSalt;
        }
      }

      stage = 'merge';
      final mergedData = remoteData != null ? localData.mergeWith(remoteData) : localData;

      stage = 'encrypt_upload';
      if (_cachedKey == null || _cachedSalt == null) {
        throw Exception("Key cache missing");
      }

      final encrypted = SyncCrypto.encryptWithKey(
        mergedData.toJsonString(),
        _cachedKey!,
        _cachedSalt!,
      );

      await _uploadRemoteEncrypted(encrypted, syncRunId);

      // 仅 GitHub 需要保存 gistId
      if (!useWebDav) {
        final currentGistId = _gistService.gistId;
        if (currentGistId != null) {
          await _storage.write(key: _keyGistId, value: currentGistId);
        }
      }

      stage = 'apply_remote';
      await _applyRemoteData(mergedData);

      _lastSyncTime = DateTime.now();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyLastSyncTime, _lastSyncTime!.toIso8601String());
      if (mergedData.syncId != null) {
        _lastKnownSyncId = mergedData.syncId;
        await prefs.setString(_keyLastSyncId, _lastKnownSyncId!);
      }

      _status = SyncStatus.idle;
      _retryCount = 0;
      _lastFailureTime = null;
      _logger.info('Sync completed successfully (backend: ${useWebDav ? "WebDAV" : "GitHub"})');
      notifyListeners();
    } catch (e) {
      _status = SyncStatus.error;
      _errorMessage = e.toString();
      _lastFailureTime = DateTime.now();

      final shouldRetry = _shouldRetryError(e);
      if (shouldRetry && _retryCount < _maxRetries) {
        _retryCount++;
        final delay = Duration(seconds: 5 * _retryCount);
        Future.delayed(delay, _runSyncTask);
      } else {
        rethrow;
      }
    } finally {
      _isSyncing = false;
      if (_pendingSyncCount > 0) {
        final count = _pendingSyncCount;
        _pendingSyncCount = 0;
        Future.microtask(_runSyncTask);
      }
    }
  }

  bool _shouldRetryError(dynamic error) {
    final errorMsg = error.toString().toLowerCase();
    if (errorMsg.contains('密码') ||
        errorMsg.contains('解密失败') ||
        errorMsg.contains('unauthorized') ||
        errorMsg.contains('token')) {
      return false;
    }
    return true;
  }

  /// 从 GitHub 恢复数据（WebDAV 模式下禁止）
  Future<bool> restoreFromGist(String password) async {
    if (useWebDav) {
      throw Exception('当前为 WebDAV 模式，请使用 restoreFromWebDav 方法');
    }
    if (!_gistService.isConnected) {
      throw Exception('未连接 GitHub');
    }

    _isSyncing = true;
    _status = SyncStatus.syncing;

    try {
      final syncRunId = DateTime.now().millisecondsSinceEpoch.toString();
      _logger.info('SYNC run=$syncRunId stage=restore_start');
      final remoteEncrypted = await _gistService.downloadFromGist(
        syncRunId: syncRunId,
      );
      if (remoteEncrypted == null) {
        _status = SyncStatus.idle;
        _logger.info('SYNC run=$syncRunId stage=restore_no_remote');
        return false;
      }

      final decrypted = await compute(_decryptInIsolate, {
        'json': remoteEncrypted,
        'pass': password,
      });

      final remoteData = SyncData.fromJson(
        (await _parseJson(decrypted)) as Map<String, dynamic>,
      );

      await _applyRemoteData(remoteData);
      await _storage.write(key: _keySyncPassword, value: password);

      final encryptedJson = jsonDecode(remoteEncrypted) as Map<String, dynamic>;
      final salt = base64Decode(encryptedJson['salt']);
      final iter = encryptedJson['iter'] as int? ?? 100000;

      _cachedKey = await compute(deriveKeyCompute, {
        'pass': password,
        'salt': salt,
        'iter': iter,
      });
      _cachedSalt = salt;

      if (remoteData.syncId != null) {
        _lastKnownSyncId = remoteData.syncId;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_keyLastSyncId, _lastKnownSyncId!);
      }

      _status = SyncStatus.idle;
      _logger.info('Restore from Gist completed');
      _logger.info('SYNC run=$syncRunId stage=restore_done');
      return true;
    } catch (e) {
      _logger.severe('Gist sync failed: $e');
      _status = SyncStatus.error;
      _errorMessage = e.toString();
      notifyListeners();
      rethrow;
    } finally {
      _isSyncing = false;
    }
  }

  /// 从 WebDAV 恢复数据
  Future<bool> restoreFromWebDav(String password) async {
    if (!_webdavService.isConnected) {
      throw Exception('未连接 WebDAV');
    }

    _isSyncing = true;
    _status = SyncStatus.syncing;

    try {
      final syncRunId = DateTime.now().millisecondsSinceEpoch.toString();
      _logger.info('SYNC run=$syncRunId stage=restore_start');
      final remoteEncrypted = await _webdavService.downloadFromWebDav(
        syncRunId: syncRunId,
      );
      if (remoteEncrypted == null) {
        _status = SyncStatus.idle;
        _logger.info('SYNC run=$syncRunId stage=restore_no_remote');
        return false;
      }

      final decrypted = await compute(_decryptInIsolate, {
        'json': remoteEncrypted,
        'pass': password,
      });

      final remoteData = SyncData.fromJson(
        (await _parseJson(decrypted)) as Map<String, dynamic>,
      );

      await _applyRemoteData(remoteData);
      await _storage.write(key: _keySyncPassword, value: password);

      final encryptedJson = jsonDecode(remoteEncrypted) as Map<String, dynamic>;
      final salt = base64Decode(encryptedJson['salt']);
      final iter = encryptedJson['iter'] as int? ?? 100000;

      _cachedKey = await compute(deriveKeyCompute, {
        'pass': password,
        'salt': salt,
        'iter': iter,
      });
      _cachedSalt = salt;

      if (remoteData.syncId != null) {
        _lastKnownSyncId = remoteData.syncId;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_keyLastSyncId, _lastKnownSyncId!);
      }

      _status = SyncStatus.idle;
      _logger.info('Restore from WebDAV completed');
      _logger.info('SYNC run=$syncRunId stage=restore_done');
      return true;
    } catch (e) {
      _logger.severe('WebDAV restore failed: $e');
      _status = SyncStatus.error;
      _errorMessage = e.toString();
      notifyListeners();
      rethrow;
    } finally {
      _isSyncing = false;
    }
  }

  /// 收集本地数据
  Future<SyncData> _collectLocalData() async {
    final packageInfo = await PackageInfo.fromPlatform();
    final appVersion = '${packageInfo.version}+${packageInfo.buildNumber}';

    final modules = <String, SyncModule>{};

    // 收集书签数据
    final bookmarks = await _bookMarkService.getAllMarkedBooks();
    if (bookmarks.isNotEmpty) {
      final bookmarkData = <String, dynamic>{};
      for (final entry in bookmarks.entries) {
        bookmarkData[entry.key.toString()] = {
          'status': entry.value.index,
          'updatedAt': DateTime.now().toIso8601String(),
        };
      }
      modules[SyncModuleNames.bookmarks] = SyncModule(
        version: 1,
        updatedAt: DateTime.now(),
        data: bookmarkData,
      );
    }

    // 收集阅读时长
    final prefs = await SharedPreferences.getInstance();
    final readingTimeData = <String, dynamic>{};
    for (final key in prefs.getKeys()) {
      if (key.startsWith('reading_time_')) {
        final dateStr = key.substring('reading_time_'.length);
        final minutes = prefs.getInt(key);
        if (minutes != null && minutes > 0) {
          readingTimeData[dateStr] = minutes;
        }
      }
    }
    if (readingTimeData.isNotEmpty) {
      modules[SyncModuleNames.readingTime] = SyncModule(
        version: 1,
        updatedAt: DateTime.now(),
        data: readingTimeData,
      );
    }

    // 收集 RefreshToken
    final refreshToken = prefs.getString('refresh_token');
    if (refreshToken != null) {
      modules[SyncModuleNames.auth] = SyncModule(
        version: 1,
        updatedAt: DateTime.now(),
        data: {'refreshToken': refreshToken},
      );
    }

    return SyncData.create(appVersion: appVersion, modules: modules);
  }

  /// 应用远程数据到本地
  Future<void> _applyRemoteData(SyncData remoteData) async {
    final prefs = await SharedPreferences.getInstance();

    // 应用书签
    final bookmarksModule = remoteData.modules[SyncModuleNames.bookmarks];
    if (bookmarksModule != null) {
      for (final entry in bookmarksModule.data.entries) {
        final bookId = int.tryParse(entry.key);
        final data = entry.value as Map<String, dynamic>?;
        if (bookId != null && data != null) {
          final status = data['status'] as int?;
          if (status != null &&
              status >= 0 &&
              status < BookMarkStatus.values.length) {
            await _bookMarkService.setBookMark(
              bookId,
              BookMarkStatus.values[status],
              skipSync: true,
            );
          }
        }
      }
    }

    // 应用阅读时长
    final readingTimeModule = remoteData.modules[SyncModuleNames.readingTime];
    if (readingTimeModule != null) {
      for (final entry in readingTimeModule.data.entries) {
        final key = 'reading_time_${entry.key}';
        final remoteMinutes = entry.value as int?;
        if (remoteMinutes != null) {
          final localMinutes = prefs.getInt(key) ?? 0;
          if (remoteMinutes > localMinutes) {
            await prefs.setInt(key, remoteMinutes);
          }
        }
      }
    }

    // 应用 RefreshToken
    final authModule = remoteData.modules[SyncModuleNames.auth];
    if (authModule != null) {
      final refreshToken = authModule.data['refreshToken'] as String?;
      if (refreshToken != null && refreshToken.isNotEmpty) {
        await prefs.setString('refresh_token', refreshToken);
      }
    }

    _logger.info('Applied remote data to local storage');
  }

  Future<dynamic> _parseJson(String json) async {
    return Future.value(__parseJsonSync(json));
  }

  dynamic __parseJsonSync(String json) {
    return json.isEmpty
        ? {}
        : (json.startsWith('{') || json.startsWith('['))
        ? _decodeJson(json)
        : {};
  }

  dynamic _decodeJson(String json) {
    try {
      return const JsonDecoder().convert(json);
    } catch (e) {
      return {};
    }
  }
}

/// Isolate 专用：后台解密
Future<String> _decryptInIsolate(Map<String, dynamic> params) async {
  final String encrypted = params['json'];
  final String password = params['pass'];
  return SyncCrypto.decrypt(encrypted, password);
}