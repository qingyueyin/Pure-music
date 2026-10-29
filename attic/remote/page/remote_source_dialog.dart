import 'package:flutter/material.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/remote/remote_source.dart';

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

  String get _addressLabel => switch (_kind) {
    RemoteSourceKind.navidrome => '服务器地址',
    RemoteSourceKind.webdav => 'WebDAV 地址',
    RemoteSourceKind.smb => '共享路径',
  };

  String get _addressHint => switch (_kind) {
    RemoteSourceKind.navidrome => 'http://192.168.1.2:4533',
    RemoteSourceKind.webdav => 'https://example.com/dav/music',
    RemoteSourceKind.smb => r'\\192.168.1.2\Music',
  };

  String get _nameHint => switch (_kind) {
    RemoteSourceKind.navidrome => '家里的 Navidrome',
    RemoteSourceKind.webdav => 'NAS 音乐',
    RemoteSourceKind.smb => '书房共享',
  };

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final smb = _kind == RemoteSourceKind.smb;
    final address = smb ? _root.text.trim() : _baseUrl.text.trim();
    Navigator.of(context).pop(
      RemoteSourceFormData(
        kind: _kind,
        name: _name.text.trim().isEmpty ? _kind.label : _name.text.trim(),
        baseUrl: address,
        username: _username.text.trim(),
        password: _password.text.isEmpty ? null : _password.text,
        root: smb ? address : '',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(_editing ? '编辑远程源' : '添加远程源'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
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
                    labelText: '名称',
                    hintText: _nameHint,
                  ),
                  validator: (value) =>
                      value == null || value.trim().isEmpty ? '请输入名称' : null,
                ),
                const SizedBox(height: Spacing.sm),
                if (_kind == RemoteSourceKind.smb)
                  TextFormField(
                    controller: _root,
                    decoration: InputDecoration(
                      labelText: _addressLabel,
                      hintText: _addressHint,
                    ),
                    validator: (value) =>
                        _validateAddress(value) ? null : '请输入有效的共享路径',
                  )
                else
                  TextFormField(
                    controller: _baseUrl,
                    decoration: InputDecoration(
                      labelText: _addressLabel,
                      hintText: _addressHint,
                    ),
                    validator: _validateUrl,
                  ),
                const SizedBox(height: Spacing.sm),
                TextFormField(
                  controller: _username,
                  decoration: const InputDecoration(labelText: '用户名'),
                ),
                const SizedBox(height: Spacing.sm),
                TextFormField(
                  controller: _password,
                  obscureText: _obscure,
                  decoration: InputDecoration(
                    labelText: '密码',
                    hintText: _editing ? '留空保持不变' : null,
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscure ? Icons.visibility : Icons.visibility_off,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ),
                const SizedBox(height: Spacing.sm),
                Text(
                  _kind == RemoteSourceKind.smb
                      ? '会先用 Windows 网络凭据连接共享，再读取音乐标签。'
                      : _kind == RemoteSourceKind.navidrome
                      ? '兼容 Subsonic API 的服务器，同步后可浏览全部歌曲。'
                      : 'WebDAV 通过目录列表读取音频文件，封面与时长可能不可用。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
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
    final uri = Uri.tryParse(text);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return '地址需以 http:// 或 https:// 开头';
    }
    return null;
  }

  bool _validateAddress(String? value) {
    final text = value?.trim() ?? '';
    return RegExp(r'^\\\\[^\\]+\\[^\\]+').hasMatch(text);
  }
}
