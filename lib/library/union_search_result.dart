import 'package:pure_music/library/audio_library.dart';

class UnionSearchResult {
  String query;

  List<Audio> audios = [];
  List<Artist> artists = [];
  List<Album> album = [];

  UnionSearchResult(this.query);

  static UnionSearchResult search(String query) {
    final result = UnionSearchResult(query);

    final queryInLowerCase = query.toLowerCase();
    final library = AudioLibrary.instance;

    for (int i = 0; i < library.audioCollection.length; i++) {
      final audio = library.audioCollection[i];
      if (audio.title.toLowerCase().contains(queryInLowerCase) ||
          audio.artist.toLowerCase().contains(queryInLowerCase) ||
          audio.album.toLowerCase().contains(queryInLowerCase)) {
        result.audios.add(audio);
      }
    }

    for (Artist item in library.artistCollection.values) {
      if (item.name.toLowerCase().contains(queryInLowerCase)) {
        result.artists.add(item);
      }
    }

    for (Album item in library.albumCollection.values) {
      if (item.name.toLowerCase().contains(queryInLowerCase)) {
        result.album.add(item);
      }
    }

    return result;
  }
}

