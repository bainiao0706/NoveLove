import 'package:flutter/material.dart';

/// 设置页面通用的 UI 辅助类
class SettingsUIHelper {
  /// 显示单选底部弹窗
  static void showSelectionSheet<T>({
    required BuildContext context,
    required String title,
    String? subtitle,
    required T currentValue,
    required Map<T, String> options,
    required Map<T, IconData> icons,
    required ValueChanged<T> onSelected,
  }) {
    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) {
        final colorScheme = Theme.of(context).colorScheme;
        final textTheme = Theme.of(context).textTheme;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Text(
                  title,
                  style: textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(
                    subtitle,
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ...options.entries.map((entry) {
                final isSelected = entry.key == currentValue;
                return ListTile(
                  leading: Icon(
                    icons[entry.key],
                    color:
                        isSelected
                            ? colorScheme.primary
                            : colorScheme.onSurfaceVariant,
                  ),
                  title: Text(
                    entry.value,
                    style: TextStyle(
                      color: isSelected ? colorScheme.primary : null,
                      fontWeight: isSelected ? FontWeight.bold : null,
                    ),
                  ),
                  trailing:
                      isSelected
                          ? Icon(Icons.check, color: colorScheme.primary)
                          : null,
                  onTap: () {
                    onSelected(entry.key);
                    Navigator.pop(context);
                  },
                );
              }),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }
}
