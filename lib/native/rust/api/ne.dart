import 'dart:convert';
import 'dart:io';

import 'package:pure_music/core/utils.dart';

const String _neSearchUrl = "https://music.163.com/api/cloudsearch/pc";
const String _neLrcUrl = "https://music.163.com/api/song/lyric";

Future<List<Map<String, dynamic>>> neSearch(String keyword,
    {int limit = 10}) async {
  try {
    final client = HttpClient();
    final uri = Uri.parse('$_neSearchUrl?s=$keyword&type=1&offset=0&total=true&limit=$limit');
    
    final request = await client.getUrl(uri);
    request.headers.set('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36');
    request.headers.set('Referer', 'https://music.163.com/');
    request.headers.set('Accept', '*/*');
    request.headers.set('Connection', 'keep-alive');
    
    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();
    
    logger.i("NetEase API response status: ${response.statusCode}");
    
    if (response.statusCode != 200) {
      logger.w("NetEase API error: $responseBody");
      return [];
    }
    
    final jsonData = jsonDecode(responseBody);
    final result = jsonData["result"];
    if (result is Map && result["songs"] != null) {
      client.close();
      return List<Map<String, dynamic>>.from(result["songs"]);
    }
    logger.w("NetEase search returned no songs for: $keyword");
    client.close();
    return [];
  } catch (e, stack) {
    logger.e("NetEase search exception: $e, stack: $stack");
    return [];
  }
}

Future<Map<String, dynamic>?> neLyric(String songId) async {
  try {
    final client = HttpClient();
    final uri = Uri.parse('$_neLrcUrl?id=$songId&lv=-1&yv=-1&tv=-1&os=pc');
    
    final request = await client.getUrl(uri);
    request.headers.set('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36');
    request.headers.set('Referer', 'https://music.163.com/');
    request.headers.set('Accept', '*/*');
    
    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();
    
    if (response.statusCode != 200) {
      logger.w("NetEase lyric API error: $responseBody");
      return null;
    }
    
    final jsonData = jsonDecode(responseBody);
    if (jsonData is Map) {
      client.close();
      return jsonData.cast<String, dynamic>();
    }
    client.close();
    return null;
  } catch (e, stack) {
    logger.e("NetEase lyric exception: $e, stack: $stack");
    return null;
  }
}
