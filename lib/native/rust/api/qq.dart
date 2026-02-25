import 'dart:convert';
import 'dart:io';

import 'package:pure_music/lyric/qrc.dart';
import 'package:pure_music/lyric/qrc_decryptor.dart';

const String _qmSearchUrl = "https://c.y.qq.com/soso/fcgi-bin/client_search_cp";
const String _qmLrcUrl = "https://c.y.qq.com/qqmusic/fcgi-bin/lyric_download.fcg";

Future<List<Map<String, dynamic>>> qqSearch(String keyword,
    {int limit = 10}) async {
  try {
    final client = HttpClient();
    final uri = Uri.parse('$_qmSearchUrl?format=json&w=$keyword&n=$limit&p=1');
    
    final request = await client.getUrl(uri);
    request.headers.set('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36');
    request.headers.set('Referer', 'https://y.qq.com/');
    request.headers.set('Accept', '*/*');
    
    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();
    
    final jsonData = jsonDecode(responseBody);
    final songList = jsonData["data"]?["song"]?["list"];
    if (songList is List) {
      client.close();
      return songList.map((item) => {
        "songid": item["songid"],
        "songname": item["songname"],
        "singer": item["singer"],
        "albummid": item["albummid"],
        "albumname": item["albumname"],
        "duration": item["interval"],
      }).toList().cast<Map<String, dynamic>>();
    }
    client.close();
    return [];
  } catch (e) {
    return [];
  }
}

Future<Qrc?> qqLyric(int songId) async {
  try {
    final client = HttpClient();
    final uri = Uri.parse('$_qmLrcUrl?version=15&lrctype=4&musicid=$songId');
    
    final request = await client.getUrl(uri);
    request.headers.set('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36');
    request.headers.set('Referer', 'https://y.qq.com/');
    request.headers.set('Accept', '*/*');
    
    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();
    client.close();
    
    if (responseBody.isEmpty) return null;
    
    final regex = RegExp(r'CDATA\[(\S+)]]');
    final extracted = regex
        .allMatches(responseBody)
        .map((m) => m.group(1))
        .whereType<String>()
        .toList();
    
    if (extracted.isEmpty) return null;
    
    final encryptedQrc = extracted[0];
    final decrypted = await qrcDecrypt(encryptedQrc: encryptedQrc, isLocal: false);
    
    if (decrypted == null || decrypted.isEmpty) return null;
    
    String? transDecrypted;
    if (extracted.length > 1) {
      final encryptedTrans = extracted[1];
      transDecrypted = await qrcDecrypt(encryptedQrc: encryptedTrans, isLocal: false);
    }
    
    if (transDecrypted != null && transDecrypted.isNotEmpty) {
      return Qrc.fromQrcText(decrypted, transDecrypted);
    }
    return Qrc.fromQrcText(decrypted);
  } catch (e) {
    return null;
  }
}
