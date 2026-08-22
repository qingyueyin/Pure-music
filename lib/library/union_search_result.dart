import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/core/search_action_state.dart';
import 'package:pure_music/core/utils.dart';

enum SearchScope { music, artist, album }

class UnionSearchResult {
  String query;

  List<Audio> audios = [];
  List<Artist> artists = [];
  List<Album> album = [];

  UnionSearchResult(this.query);

  static bool _matchesQuery(String text, String queryInLowerCase) {
    if (normalizedSearchQuery(text).toLowerCase().contains(queryInLowerCase)) {
      return true;
    }
    return text.getPinyinInitials().toLowerCase().contains(queryInLowerCase);
  }

  static UnionSearchResult search(String query, {SearchScope? scope}) {
    final normalizedQuery = normalizedSearchQuery(query);
    final result = UnionSearchResult(normalizedQuery);

    final queryInLowerCase = normalizedQuery.toLowerCase();
    final library = AudioLibrary.instance;

    if (scope == null || scope == SearchScope.music) {
      for (int i = 0; i < library.audioCollection.length; i++) {
        final audio = library.audioCollection[i];
        if (_matchesQuery(audio.title, queryInLowerCase)) {
          result.audios.add(audio);
        }
      }
    }

    if (scope == null || scope == SearchScope.artist) {
      for (Artist item in library.artistCollection.values) {
        if (_matchesQuery(item.name, queryInLowerCase)) {
          result.artists.add(item);
        }
      }
    }

    if (scope == null || scope == SearchScope.album) {
      for (Album item in library.albumCollection.values) {
        if (_matchesQuery(item.name, queryInLowerCase)) {
          result.album.add(item);
        }
      }
    }

    return result;
  }
}
