import 'package:webdav_client/webdav_client.dart' as dav;
import 'package:logging/logging.dart';

class WebDavSyncService {
  static final Logger _logger = Logger('WebDavSyncService');
  dav.Client? _client;
  // 备份文件名，你可以自定义
  final String _remoteFileName = 'novelove_sync_data.bin';

  /// 初始化连接
  void init(String host, String user, String password) {
    _client = dav.newClient(
      host,
      user: user,
      password: password,
      debug: true,
    );
    _logger.info('WebDAV 客户端初始化成功');
  }

  bool get isConnected => _client != null;

  /// 上传数据
  Future<void> upload(String encryptedData) async {
    if (_client == null) throw Exception("WebDAV 未初始化");
    // 将加密后的文本转为字节流写入服务器
    await _client!.write(_remoteFileName, encryptedData.codeUnits);
  }

  /// 下载数据
  Future<String?> download() async {
    if (_client == null) throw Exception("WebDAV 未初始化");
    try {
      final data = await _client!.read(_remoteFileName);
      return String.fromCharCodes(data);
    } catch (e) {
      _logger.warning('未找到云端备份文件');
      return null;
    }
  }
}