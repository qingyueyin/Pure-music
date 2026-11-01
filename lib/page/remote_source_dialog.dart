import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/remote/remote_source.dart';
import 'package:pure_music/remote/url_probe.dart';

class RemoteSourceFormData {
  const RemoteSourceFormData({
    required this.kind,
    required this.name,
    required this.baseUrl,
    required this.username,
    required this.password,
    required this.root,
  });

  final RemoteSourceKind kind;
  final String name;
  final String baseUrl;
  final String username;
  final String? password;
  final String root;
}

Future<RemoteSourceFormData?> showRemoteSourceDialog(
  BuildContext context, {
  RemoteSource? source,
}) {
  return showDialog<RemoteSourceFormData>(
    context: context,
    builder: (context) => _RemoteSourceDialog(source: source),
  );
}

class _RemoteSourceDialog extends StatefulWidget {
  const _RemoteSourceDialog({this.source});

  final RemoteSource? source;

  @override
  State<_RemoteSourceDialog> createState() => _RemoteSourceDialogState();
}

class _RemoteSourceDialogState extends State<_RemoteSourceDialog> {
  late RemoteSourceKind _kind;
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _root;
  final _formKey = GlobalKey<FormState>();
  bool _obscure = true;

  bool get _editing => widget.source != null;

  @override
  void initState() {
    super.initState();
    final source = widget.source;
    _kind = source?.kind ?? RemoteSourceKind.navidrome;
    _name = TextEditingController(text: source?.name ?? '');
    _baseUrl = TextEditingController(text: source?.baseUrl ?? '');
    _username = TextEditingController(text: source?.username ?? '');
    _password = TextEditingController();
    _root = TextEditingController(text: source?.root ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _username.dispose();
    _password.dispose();
    _root.dispose();
    super.dispose();
  }

  /// 用 API 密钥时不需要用户名，这里直接说清楚，省得两个框都填。
  String get _usernameLabel => switch (_kind) {
    RemoteSourceKind.jellyfin => '用户名（可选）',
    _ => '用户名',
  };

  String? get _usernameHelper {
    if (_mountedDrive) return '远程磁盘无需输入';
    return switch (_kind) {
      RemoteSourceKind.jellyfin => '当下方填写API密钥时用户名一栏请留空',
      _ => null,
    };
  }

  String get _passwordLabel => switch (_kind) {
    RemoteSourceKind.jellyfin => '密码 / API 密钥',
    _ => '密码',
  };

  String? get _passwordHelper {
    if (_mountedDrive) return '远程磁盘无需输入';
    return switch (_kind) {
      RemoteSourceKind.smb => '留空则使用Windows保存的凭据',
      _ => null,
    };
  }

  String get _description => switch (_kind) {
    RemoteSourceKind.smb => '会先用 Windows 网络凭据连接共享，再读取音乐标签。',
    RemoteSourceKind.navidrome => '兼容 Subsonic API 的服务器，同步后可浏览全部歌曲。',
    RemoteSourceKind.jellyfin => '',
    RemoteSourceKind.webdav => 'WebDAV 通过目录列表读取音频文件，封面与时长可能不可用。',
  };

  String get _addressLabel => switch (_kind) {
    RemoteSourceKind.navidrome => '服务器地址',
    RemoteSourceKind.webdav => 'WebDAV 地址',
    RemoteSourceKind.smb => '共享路径',
    RemoteSourceKind.jellyfin => 'Jellyfin 地址',
  };

  String get _addressHint => switch (_kind) {
    RemoteSourceKind.navidrome => '192.168.1.2:4533',
    RemoteSourceKind.webdav => '192.168.1.2:8080/dav/music',
    RemoteSourceKind.smb => r'\\192.168.1.2\Music',
    RemoteSourceKind.jellyfin => '192.168.1.2:8096',
  };

  String get _nameHint => switch (_kind) {
    RemoteSourceKind.navidrome => '家里的 Navidrome',
    RemoteSourceKind.webdav => 'NAS 音乐',
    RemoteSourceKind.smb => '书房共享',
    RemoteSourceKind.jellyfin => '家中的 Jellyfin',
  };

  String get _address =>
      (_kind == RemoteSourceKind.smb ? _root.text : _baseUrl.text).trim();

  String get _autoName => defaultRemoteSourceName(_kind, _address);

  /// 已挂载成本地盘符的远程磁盘（Z://Music）：不需要账号密码。
  bool get _mountedDrive =>
      _kind == RemoteSourceKind.smb &&
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(_root.text.trim());

  Future<void> _pickFolder() async {
    final selected = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择音乐文件夹',
    );
    if (selected == null || selected.trim().isEmpty) return;
    setState(() => _root.text = selected);
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final smb = _kind == RemoteSourceKind.smb;
    final address = smb ? _root.text.trim() : _baseUrl.text.trim();
    final name = _name.text.trim();
    Navigator.of(context).pop(
      RemoteSourceFormData(
        kind: _kind,
        // 名称留空就原样传空，交给 saveSource 生成默认名并处理重名（Navidrome (2)）。
        name: name,
        baseUrl: address,
        username: _mountedDrive ? '' : _username.text.trim(),
        password: _mountedDrive || _password.text.isEmpty
            ? null
            : _password.text,
        root: smb ? address : '',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(_editing ? '编辑远程源' : '添加远程源'),
      content: SizedBox(
        width: 440,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<RemoteSourceKind>(
                  initialValue: _kind,
                  decoration: const InputDecoration(labelText: '类型'),
                  items: RemoteSourceKind.values
                      .map(
                        (kind) => DropdownMenuItem(
                          value: kind,
                          child: Text(kind.label),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      _kind = value;
                      if (value == RemoteSourceKind.smb && _root.text.isEmpty) {
                        _root.text = _baseUrl.text;
                      }
                    });
                  },
                ),
                const SizedBox(height: Spacing.sm),
                TextFormField(
                  controller: _name,
                  decoration: InputDecoration(
                    labelText: '名称（可留空）',
                    hintText: _nameHint,
                    helperText: '留空将自动命名为「$_autoName」',
                  ),
                ),
                const SizedBox(height: Spacing.sm),
                if (_kind == RemoteSourceKind.smb)
                  TextFormField(
                    controller: _root,
                    decoration: InputDecoration(
                      labelText: _addressLabel,
                      hintText: _addressHint,
                      helperText: _mountedDrive
                          ? '已挂载的远程磁盘，按本地目录直接扫描'
                          : null,
                      suffixIcon: IconButton(
                        tooltip: '选择文件夹',
                        icon: const Icon(Symbols.folder_open),
                        onPressed: _pickFolder,
                      ),
                    ),
                    onChanged: (_) => setState(() {}),
                    validator: (value) => _validateAddress(value)
                        ? null
                        : r'请输入 \服务器\共享名 或已挂载的盘符路径',
                  )
                else
                  TextFormField(
                    controller: _baseUrl,
                    decoration: InputDecoration(
                      labelText: _addressLabel,
                      hintText: _addressHint,
                    ),
                    onChanged: (_) => setState(() {}),
                    validator: _validateUrl,
                  ),
                const SizedBox(height: Spacing.sm),
                TextFormField(
                  controller: _username,
                  enabled: !_mountedDrive,
                  decoration: InputDecoration(
                    labelText: _usernameLabel,
                    helperText: _usernameHelper ?? '',
                  ),
                ),
                const SizedBox(height: Spacing.sm),
                TextFormField(
                  controller: _password,
                  enabled: !_mountedDrive,
                  obscureText: _obscure,
                  decoration: InputDecoration(
                    labelText: _passwordLabel,
                    hintText: _editing ? '留空保持不变' : null,
                    helperText: _passwordHelper ?? '',
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscure ? Icons.visibility : Icons.visibility_off,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ),
                const SizedBox(height: Spacing.sm),
                // 固定高度：Jellyfin 没有说明文字，保留占位才能让四种类型等高。
                SizedBox(
                  height: 40,
                  child: _description.isEmpty
                      ? null
                      : Text(
                          _description,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: Text(_editing ? '保存' : '添加')),
      ],
    );
  }

  String? _validateUrl(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return '请输入地址';
    if (text.contains(RegExp(r'\s'))) return '地址里不能有空格';
    if (hasUrlScheme(text)) {
      final uri = Uri.tryParse(text);
      if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
        return '只支持 http:// 或 https://';
      }
      return uri.host.isEmpty ? '地址缺少主机名' : null;
    }
    // 省略协议：host[:port][/path] 即可。
    final hostPart = text.split('/').first;
    if (hostPart.isEmpty) return '请输入主机名或 IP';
    if (hostPart.contains(':') &&
        !RegExp(r'^\[[^\]]+\](:\d+)?$').hasMatch(hostPart) &&
        !RegExp(r'^[^:]+(:\d+)?$').hasMatch(hostPart)) {
      return '端口需为数字';
    }
    return null;
  }

  bool _validateAddress(String? value) {
    final text = value?.trim() ?? '';
    // 已挂载的盘符路径（Z://Music）也是合法输入。
    if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(text)) return true;
    return RegExp(r'^\\\\[^\\]+\\[^\\]+').hasMatch(text);
  }
}
