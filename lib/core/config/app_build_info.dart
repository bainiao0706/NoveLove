class AppBuildInfo {
  const AppBuildInfo._();

  static const String commitId = String.fromEnvironment(
    'COMMIT_ID',
    defaultValue: 'local',
  );

  static bool get isLocalBuild => commitId == 'local';

  static String getDisplayVersion(String baseVersion) {
    final normalizedVersion = baseVersion.trim();
    if (normalizedVersion.isEmpty) {
      return '';
    }

    return isLocalBuild
        ? '$normalizedVersion (Local Build)'
        : '$normalizedVersion ($commitId)';
  }
}
