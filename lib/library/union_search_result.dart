import 'package:pure_music/library/audio_library.dart';

enum SearchScope { music, artist, album }

class UnionSearchResult {
  String query;

  List<Audio> audios = [];
  List<Artist> artists = [];
  List<Album> album = [];

  UnionSearchResult(this.query);

  static UnionSearchResult search(String query, {SearchScope? scope}) {
    final result = UnionSearchResult(query);

    final queryInLowerCase = query.toLowerCase();
    final library = AudioLibrary.instance;

    if (scope == null || scope == SearchScope.music) {
      for (int i = 0; i < library.audioCollection.length; i++) {
        final audio = library.audioCollection[i];
        if (audio.title.toLowerCase().contains(queryInLowerCase)) {
          result.audios.add(audio);
        }
      }
    }

    if (scope == null || scope == SearchScope.artist) {
      for (Artist item in library.artistCollection.values) {
        if (item.name.toLowerCase().contains(queryInLowerCase)) {
          result.artists.add(item);
        }
      }
    }

    if (scope == null || scope == SearchScope.album) {
      for (Album item in library.albumCollection.values) {
        if (item.name.toLowerCase().contains(queryInLowerCase)) {
          result.album.add(item);
        }
      }
    }

    return result;
  }
}

