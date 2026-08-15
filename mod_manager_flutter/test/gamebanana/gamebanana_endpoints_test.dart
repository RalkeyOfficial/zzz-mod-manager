import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_enums.dart';
import 'package:mod_manager_flutter/services/gamebanana/gamebanana_endpoints.dart';

/// URL building. The API rejects a malformed request with a bare 400 that never
/// says which value would have worked, so these assertions are the cheapest
/// place to catch that whole class of bug.
void main() {
  const endpoints = GameBananaEndpoints(gameId: 19567);

  group('Mod/Index', () {
    test('brackets in _aFilters are percent-encoded', () {
      // Unencoded brackets are the single easiest 400 to ship.
      final uri = endpoints.modIndex();
      expect(uri.toString(), contains('_aFilters%5BGeneric_Game%5D=19567'));
      expect(uri.toString(), isNot(contains('_aFilters[')));
    });

    test('builds the full browse request', () {
      final uri = endpoints.modIndex(
        categoryId: 30395,
        sort: GbModSort.mostLiked,
        page: 2,
        perPage: 20,
      );
      expect(uri.path, '/apiv13/Mod/Index');
      expect(uri.queryParameters, {
        '_aFilters[Generic_Game]': '19567',
        '_aFilters[Generic_Category]': '30395',
        '_sSort': 'Generic_MostLiked',
        '_nPerpage': '20',
        '_nPage': '2',
      });
    });

    test('omits filters that were not supplied', () {
      final uri = endpoints.modIndex();
      expect(uri.queryParameters.containsKey('_aFilters[Generic_Category]'),
          isFalse);
      expect(uri.queryParameters.containsKey('_aFilters[Generic_Submitter]'),
          isFalse);
    });

    test('always sends a sort', () {
      expect(endpoints.modIndex().queryParameters['_sSort'], 'Generic_Newest');
    });

    test('clamps perPage to 50 instead of triggering INVALID_PERPAGE', () {
      expect(endpoints.modIndex(perPage: 100).queryParameters['_nPerpage'], '50');
      expect(endpoints.modIndex(perPage: 0).queryParameters['_nPerpage'], '1');
    });

    test('normalises a nonsensical page number', () {
      expect(endpoints.modIndex(page: 0).queryParameters['_nPage'], '1');
      expect(endpoints.modIndex(page: -3).queryParameters['_nPage'], '1');
    });

    test('every sort maps to a verified wire alias', () {
      for (final sort in GbModSort.values) {
        expect(sort.wireValue, startsWith('Generic_'));
        expect(endpoints.modIndex(sort: sort).queryParameters['_sSort'],
            sort.wireValue);
      }
    });
  });

  group('Util/Search/Results', () {
    test('uses _idGameRow, NOT the Index filter spelling', () {
      // The two endpoints scope by game with different parameter names and no
      // overlap; sending Index's spelling here silently drops the game scope
      // and returns results from every game on the site.
      final uri = endpoints.search('ellen');
      expect(uri.queryParameters['_idGameRow'], '19567');
      expect(uri.toString(), isNot(contains('_aFilters')));
    });

    test('builds the search request', () {
      final uri = endpoints.search('ellen', page: 3);
      expect(uri.path, '/apiv13/Util/Search/Results');
      expect(uri.queryParameters, {
        '_sModelName': 'Mod',
        '_sSearchString': 'ellen',
        '_idGameRow': '19567',
        '_nPage': '3',
      });
    });

    test('never sends _nPerpage, because the server caps it silently', () {
      expect(endpoints.search('x').queryParameters.containsKey('_nPerpage'),
          isFalse);
    });

    test('encodes a query with spaces and symbols', () {
      final uri = endpoints.search('ellen joe & co');
      expect(uri.queryParameters['_sSearchString'], 'ellen joe & co');
      expect(uri.toString(), isNot(contains(' ')));
    });
  });

  group('Mod/<id> paths', () {
    test('profile', () {
      expect(endpoints.modProfile(531649).toString(),
          'https://gamebanana.com/apiv13/Mod/531649/ProfilePage');
    });

    test('download page', () {
      expect(endpoints.modDownloadPage(531649).toString(),
          'https://gamebanana.com/apiv13/Mod/531649/DownloadPage');
    });

    test('updates feed takes no parameters', () {
      // `_nPerpage` is left at the server's default of 5 deliberately: the
      // question is always about the newest release, and a mod with fifty
      // update posts would otherwise tempt a caller into paging all of them.
      expect(endpoints.modUpdates(531649).toString(),
          'https://gamebanana.com/apiv13/Mod/531649/Updates');
    });
  });

  group('Mod/Categories', () {
    test('always sends _sSort, which the endpoint requires', () {
      // Its own internal default is a value it does not accept, so omitting
      // _sSort is an error every single time.
      expect(endpoints.categories().queryParameters['_sSort'], 'a_to_z');
      expect(
          endpoints.categories(categoryId: 30305).queryParameters['_sSort'],
          'a_to_z');
      expect(endpoints.categories(sort: GbCategorySort.count)
          .queryParameters['_sSort'], 'count');
    });

    test('scopes by game for roots and by category for children', () {
      final roots = endpoints.categories();
      expect(roots.queryParameters['_idGameRow'], '19567');
      expect(roots.queryParameters.containsKey('_idCategoryRow'), isFalse);

      final children = endpoints.categories(categoryId: 30305);
      expect(children.queryParameters['_idCategoryRow'], '30305');
      expect(children.queryParameters.containsKey('_idGameRow'), isFalse);
    });

    test('uses the category sort vocabulary, not the mod one', () {
      for (final sort in GbCategorySort.values) {
        expect(sort.wireValue, isNot(startsWith('Generic_')));
      }
    });
  });

  group('Mod/Multi', () {
    test('joins ids and properties as CSV', () {
      final uri = endpoints.modsMulti(
        [531649, 528481],
        ['_idRow', '_sName', '_aFiles'],
      );
      expect(uri.path, '/apiv13/Mod/Multi');
      expect(uri.queryParameters['_csvRowIds'], '531649,528481');
      expect(uri.queryParameters['_csvProperties'], '_idRow,_sName,_aFiles');
    });
  });

  test('query parameter order is stable, so cache keys are deterministic', () {
    expect(endpoints.modIndex(categoryId: 1, page: 2, perPage: 10).toString(),
        endpoints.modIndex(categoryId: 1, page: 2, perPage: 10).toString());
  });

  test('a client with no game id omits the game scope entirely', () {
    const unscoped = GameBananaEndpoints();
    expect(unscoped.modIndex().toString(), isNot(contains('Generic_Game')));
    expect(unscoped.search('x').queryParameters.containsKey('_idGameRow'),
        isFalse);
  });
}
