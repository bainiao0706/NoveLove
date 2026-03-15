import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

/// 阅读背景颜色选择器底部弹窗
/// 支持分别选择背景色和文字色
class ReaderColorPickerSheet extends StatefulWidget {
  final Color initialBackgroundColor;
  final Color initialTextColor;
  final ValueChanged<Color> onBackgroundColorChange;
  final ValueChanged<Color> onTextColorChange;

  const ReaderColorPickerSheet({
    super.key,
    required this.initialBackgroundColor,
    required this.initialTextColor,
    required this.onBackgroundColorChange,
    required this.onTextColorChange,
  });

  @override
  State<ReaderColorPickerSheet> createState() => _ReaderColorPickerSheetState();
}

class _ReaderColorPickerSheetState extends State<ReaderColorPickerSheet>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late Color _backgroundColor;
  late Color _textColor;
  late TextEditingController _bgHexController;
  late TextEditingController _textHexController;
  final _bgFocusNode = FocusNode();
  final _textFocusNode = FocusNode();
  String? _bgErrorText;
  String? _textErrorText;

  // 指针交互状态
  bool _isTrackingPointer = false;
  bool _hasPointerMoved = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _backgroundColor = widget.initialBackgroundColor;
    _textColor = widget.initialTextColor;
    _bgHexController = TextEditingController(
      text:
          '#${_backgroundColor.toARGB32().toRadixString(16).toUpperCase().substring(2)}',
    );
    _textHexController = TextEditingController(
      text:
          '#${_textColor.toARGB32().toRadixString(16).toUpperCase().substring(2)}',
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    _bgHexController.dispose();
    _textHexController.dispose();
    _bgFocusNode.dispose();
    _textFocusNode.dispose();
    super.dispose();
  }

  void _onBackgroundColorChanged(Color color) {
    setState(() {
      _backgroundColor = color;
    });

    if (!_bgFocusNode.hasFocus) {
      final hex = color.toARGB32().toRadixString(16).toUpperCase().substring(2);
      _bgHexController.text = '#$hex';
      _bgErrorText = null;
    }

    if (!_isTrackingPointer) {
      widget.onBackgroundColorChange(color);
    }
  }

  void _onTextColorChanged(Color color) {
    setState(() {
      _textColor = color;
    });

    if (!_textFocusNode.hasFocus) {
      final hex = color.toARGB32().toRadixString(16).toUpperCase().substring(2);
      _textHexController.text = '#$hex';
      _textErrorText = null;
    }

    if (!_isTrackingPointer) {
      widget.onTextColorChange(color);
    }
  }

  void _onBgHexChanged(String value) {
    if (value.isEmpty) return;

    String hex = value.replaceAll('#', '');
    if (hex.length == 6) {
      final validHex = RegExp(r'^[0-9a-fA-F]{6}$');
      if (validHex.hasMatch(hex)) {
        try {
          final color = Color(int.parse('FF$hex', radix: 16));
          setState(() {
            _backgroundColor = color;
            _bgErrorText = null;
          });
          widget.onBackgroundColorChange(color);
        } catch (e) {
          // 解析失败
        }
      } else {
        setState(() {
          _bgErrorText = '格式错误';
        });
      }
    } else if (hex.length > 6) {
      setState(() {
        _bgErrorText = '格式错误';
      });
    } else {
      if (_bgErrorText != null) {
        setState(() {
          _bgErrorText = null;
        });
      }
    }
  }

  void _onTextHexChanged(String value) {
    if (value.isEmpty) return;

    String hex = value.replaceAll('#', '');
    if (hex.length == 6) {
      final validHex = RegExp(r'^[0-9a-fA-F]{6}$');
      if (validHex.hasMatch(hex)) {
        try {
          final color = Color(int.parse('FF$hex', radix: 16));
          setState(() {
            _textColor = color;
            _textErrorText = null;
          });
          widget.onTextColorChange(color);
        } catch (e) {
          // 解析失败
        }
      } else {
        setState(() {
          _textErrorText = '格式错误';
        });
      }
    } else if (hex.length > 6) {
      setState(() {
        _textErrorText = '格式错误';
      });
    } else {
      if (_textErrorText != null) {
        setState(() {
          _textErrorText = null;
        });
      }
    }
  }

  Widget _buildColorPicker({
    required Color color,
    required ValueChanged<Color> onColorChanged,
    required TextEditingController hexController,
    required FocusNode focusNode,
    required String? errorText,
    required ValueChanged<String> onHexChanged,
    required String label,
  }) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 颜色选择器
          Listener(
            onPointerDown: (_) {
              _isTrackingPointer = true;
              _hasPointerMoved = false;
            },
            onPointerMove: (_) {
              _hasPointerMoved = true;
            },
            onPointerUp: (_) {
              _isTrackingPointer = false;
              if (_hasPointerMoved) {
                onColorChanged(color);
                if (!focusNode.hasFocus) {
                  final hex = color
                      .toARGB32()
                      .toRadixString(16)
                      .toUpperCase()
                      .substring(2);
                  hexController.text = '#$hex';
                }
              }
            },
            child: ColorPicker(
              pickerColor: color,
              onColorChanged: onColorChanged,
              colorPickerWidth: 280,
              pickerAreaHeightPercent: 0.7,
              enableAlpha: false,
              displayThumbColor: true,
              hexInputBar: false,
              paletteType: PaletteType.hsvWithHue,
              labelTypes: const [],
            ),
          ),

          const SizedBox(height: 16),

          // HEX 输入
          TextField(
            controller: hexController,
            focusNode: focusNode,
            decoration: InputDecoration(
              labelText: '$label HEX 颜色代码',
              hintText: '#RRGGBB',
              errorText: errorText,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.tag, size: 20),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
            ),
            inputFormatters: [
              LengthLimitingTextInputFormatter(7),
              FilteringTextInputFormatter.allow(RegExp(r'[#0-9a-fA-F]')),
            ],
            onChanged: onHexChanged,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 标题
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '自定义颜色',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),

        // Tab 栏
        TabBar(
          controller: _tabController,
          tabs: const [Tab(text: '背景色'), Tab(text: '文字色')],
          labelColor: colors.primary,
          unselectedLabelColor: colors.onSurfaceVariant,
          indicatorColor: colors.primary,
        ),

        // Tab 内容
        SizedBox(
          height: 400,
          child: TabBarView(
            controller: _tabController,
            children: [
              // 背景色选择
              _buildColorPicker(
                color: _backgroundColor,
                onColorChanged: _onBackgroundColorChanged,
                hexController: _bgHexController,
                focusNode: _bgFocusNode,
                errorText: _bgErrorText,
                onHexChanged: _onBgHexChanged,
                label: '背景',
              ),
              // 文字色选择
              _buildColorPicker(
                color: _textColor,
                onColorChanged: _onTextColorChanged,
                hexController: _textHexController,
                focusNode: _textFocusNode,
                errorText: _textErrorText,
                onHexChanged: _onTextHexChanged,
                label: '文字',
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),
      ],
    );
  }
}
