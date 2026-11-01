import 'dart:async';
import 'dart:io';

import 'package:pure_music/remote/remote_source.dart';

final _schemePattern = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://');

/// 地址里是否已经带了协议（`http://`、`https://` …）。
bool hasUrlScheme(String input) => _schemePattern.hasMatch(input.trim());

/// 各服务的默认端口。只在用户没写端口时用来拼候选地址。
int? defaultPortForKind(RemoteSourceKind kind) => switch (kind) {
  RemoteSourceKind.jellyfin => 8096,
  RemoteSourceKind.navidrome => 4533,
  _ => null,
};

/// 去掉结尾多余的斜杠，但保留根路径的单个 `/`。
String stripTrailingSlash(String url) {
  var text = url.trim();
  while (text.length > 1 && text.endsWith('/')) {
    text = text.substring(0, text.length - 1);
  }
  return text;
}

bool _hasExplicitPort(String hostPart) {
  // host:port / [::1]:port；纯 IPv6 字面量不带方括号的情况在这里不用管。
  final bracket = RegExp(r'^\[[^\]]+\]:\d+$');
  if (bracket.hasMatch(hostPart)) return true;
  return RegExp(r'^[^:]+:\d+$').hasMatch(hostPart);
}

/// 判断是不是局域网 / 本机地址。只有这类地址才允许自动回退到明文 HTTP：
/// 公网上的 HTTP 会把凭据裸奔在网络上，必须由用户显式写 `http://` 才用。
bool isPrivateHost(String hostPart) {
  var host = hostPart.trim();
  if (host.startsWith('[')) {
    final close = host.indexOf(']');
    if (close > 0) host = host.substring(1, close);
  } else {
    final colon = host.indexOf(':');
    if (colon > 0) host = host.substring(0, colon);
  }
  host = host.toLowerCase();
  if (host.isEmpty || host == 'localhost') return true;
  if (host.endsWith('.local') || host.endsWith('.lan')) return true;
  final ip = InternetAddress.tryParse(host);
  if (ip == null) return false;
  if (ip.type == InternetAddressType.IPv6) {
    return ip.isLoopback ||
        ip.isLinkLocal ||
        host.startsWith('fc') ||
        host.startsWith('fd') ||
        host.startsWith('fe80');
  }
  final parts = host.split('.');
  if (parts.length != 4) return false;
  final first = int.tryParse(parts[0]) ?? -1;
  final second = int.tryParse(parts[1]) ?? -1;
  return first == 127 ||
      first == 10 ||
      (first == 172 && second >= 16 && second <= 31) ||
      (first == 192 && second == 168) ||
      (first == 169 && second == 254);
}

/// 把用户输入的地址补全成可用的 baseUrl。
///
/// - 已带协议：原样返回（只去尾部斜杠），不探测，避免自签证书等场景被改写。
/// - 没带协议：先试各服务的默认端口（避免主机默认端口上的无关服务抢答），
///   再试主机默认端口；`https` 优先。明文 `http` 只对局域网 / 本机地址
///   自动回退——公网想用 http 必须显式写出来。
///
/// 探测只要求「连得上」：401 / 404 / 405 都算通，说明主机和端口是活的。
Future<String> resolveRemoteBaseUrl(
  String input, {
  RemoteSourceKind? kind,
  Duration timeout = const Duration(milliseconds: 1500),
}) async {
  final text = input.trim();
  if (text.isEmpty) return text;
  if (hasUrlScheme(text)) return stripTrailingSlash(text);

  final slash = text.indexOf('/');
  final hostPart = slash < 0 ? text : text.substring(0, slash);
  final pathPart = slash < 0 ? '' : text.substring(slash);
  final allowPlainHttp = isPrivateHost(hostPart);

  const schemes = ['https', 'http'];
  final candidates = <String>[];
  final port = kind == null ? null : defaultPortForKind(kind);
  // 服务专用端口排在前面：主机默认端口（443/80）上可能挂着无关服务，
  // 先抢答会把错误的地址存进配置。
  if (port != null && !_hasExplicitPort(hostPart)) {
    for (final scheme in schemes) {
      if (scheme == 'http' && !allowPlainHttp) continue;
      candidates.add('$scheme://$hostPart:$port$pathPart');
    }
  }
  for (final scheme in schemes) {
    if (scheme == 'http' && !allowPlainHttp) continue;
    candidates.add('$scheme://$hostPart$pathPart');
  }

  for (final candidate in candidates) {
    if (await _reachable(candidate, timeout)) {
      return stripTrailingSlash(candidate);
    }
  }
  // 都连不上：退回一个猜测地址，让后续请求给出明确报错。
  return stripTrailingSlash('${allowPlainHttp ? 'http' : 'https'}://$text');
}

/// 只发一个 GET 看有没有响应。不校验状态码 —— 有响应就说明主机活着。
Future<bool> _reachable(String url, Duration timeout) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client.getUrl(Uri.parse(url)).timeout(timeout);
    request.headers.set(HttpHeaders.userAgentHeader, 'PureMusic/probe');
    final response = await request.close().timeout(timeout);
    await response.drain<void>().timeout(timeout);
    return true;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}
