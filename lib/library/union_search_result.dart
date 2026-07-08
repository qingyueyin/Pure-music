import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/core/search_action_state.dart';

enum SearchScope { music, artist, album }

class UnionSearchResult {
  String query;

  List<Audio> audios = [];
  List<Artist> artists = [];
  List<Album> album = [];

  UnionSearchResult(this.query);

  static UnionSearchResult search(String query, {SearchScope? scope}) {
    final normalizedQuery = normalizedSearchQuery(query);
    final result = UnionSearchResult(normalizedQuery);

    final queryInLowerCase = normalizedQuery.toLowerCase();
    final library = AudioLibrary.instance;

    if (scope == null || scope == SearchScope.music) {
      for (int i = 0; i < library.audioCollection.length; i++) {
        final audio = library.audioCollection[i];
        if (normalizedSearchQuery(audio.title)
            .toLowerCase()
            .contains(queryInLowerCase)) {
          result.audios.add(audio);
        }
      }
    }

    if (scope == null || scope == SearchScope.artist) {
      for (Artist item in library.artistCollection.values) {
        if (normalizedSearchQuery(item.name)
            .toLowerCase()
            .contains(queryInLowerCase)) {
          result.artists.add(item);
        }
      }
    }

    if (scope == null || scope == SearchScope.album) {
      for (Album item in library.albumCollection.values) {
        if (normalizedSearchQuery(item.name)
            .toLowerCase()
            .contains(queryInLowerCase)) {
          result.album.add(item);
        }
      }
    }

    return result;
  }
}
