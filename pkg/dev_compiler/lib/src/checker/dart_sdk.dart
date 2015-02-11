/// Common logic needed to provide a Dart SDK to the analyzer's resolver. This
/// includes logic to determine where the sdk is located in the filesystem, and
/// definitions to provide mock sdks.
library ddc.src.checker.dart_sdk;

import 'package:ddc_analyzer/src/generated/engine.dart';
import 'package:ddc_analyzer/src/generated/sdk.dart';
import 'package:ddc_analyzer/src/generated/source.dart';

/// Dart SDK which contains a mock implementation of the SDK libraries. May be
/// used to speed up execution when most of the core libraries is not needed.
class MockDartSdk implements DartSdk {
  final Map<Uri, _MockSdkSource> _sources = {};
  final bool reportMissing;
  final Map<String, SdkLibrary> _libs = {};
  final String sdkVersion = '0';
  List<String> get uris => _sources.keys.map((uri) => '$uri').toList();
  final AnalysisContext context = new SdkAnalysisContext();
  DartUriResolver _resolver;
  DartUriResolver get resolver => _resolver;

  MockDartSdk(Map<String, String> sources, {this.reportMissing}) {
    sources.forEach((uriString, contents) {
      var uri = Uri.parse(uriString);
      _sources[uri] = new _MockSdkSource(uri, contents);
      _libs[uriString] = new SdkLibraryImpl(uri.path)
        ..setDart2JsLibrary()
        ..setVmLibrary();
    });
    _resolver = new DartUriResolver(this);
    context.sourceFactory = new SourceFactory([_resolver]);
  }

  List<SdkLibrary> get sdkLibraries => _libs.values.toList();
  SdkLibrary getSdkLibrary(String dartUri) => _libs[dartUri];
  Source mapDartUri(String dartUri) => _getSource(Uri.parse(dartUri));

  Source fromEncoding(UriKind kind, Uri uri) {
    if (kind != UriKind.DART_URI) {
      throw new UnsupportedError('expected dart: uri kind, got $kind.');
    }
    return _getSource(uri);
  }

  Source _getSource(Uri uri) {
    var src = _sources[uri];
    if (src == null) {
      if (reportMissing) print('warning: missing mock for $uri.');
      _sources[uri] =
          src = new _MockSdkSource(uri, 'library dart.${uri.path};');
    }
    return src;
  }

  @override
  Source fromFileUri(Uri uri) {
    throw new UnsupportedError('MockDartSdk.fromFileUri');
  }
}

class _MockSdkSource implements Source {
  /// Absolute URI which this source can be imported from.
  final Uri uri;
  final String _contents;

  _MockSdkSource(this.uri, this._contents);

  bool exists() => true;

  int get hashCode => uri.hashCode;

  final int modificationStamp = 1;

  TimestampedData<String> get contents =>
      new TimestampedData(modificationStamp, _contents);

  String get encoding => "${uriKind.encoding}$uri";

  String get fullName => shortName;

  String get shortName => uri.path;

  UriKind get uriKind => UriKind.DART_URI;

  bool get isInSystemLibrary => true;

  Source resolveRelative(Uri relativeUri) =>
      throw new UnsupportedError('not expecting relative urls in dart: mocks');

  Uri resolveRelativeUri(Uri relativeUri) =>
      throw new UnsupportedError('not expecting relative urls in dart: mocks');
}

/// Sample mock SDK sources.
final Map<String, String> mockSdkSources = {
  // The list of types below is derived from:
  //   * types we use via our smoke queries, including HtmlElement and
  //     types from `_typeHandlers` (deserialize.dart)
  //   * types that are used internally by the resolver (see
  //   _initializeFrom in resolver.dart).
  'dart:core': '''
        library dart.core;

        void print(Object o) {}

        class Object {
          String toString(){}
        }
        class Function {}
        class StackTrace {}
        class Symbol {}
        class Type {}

        class String extends Object {}
        class bool extends Object {}
        class num extends Object {
          num operator +(num other) {}
        }
        class int extends num {}
        class double extends num {}
        class DateTime extends Object {}
        class Null extends Object {}

        class Deprecated extends Object {
          final String expires;
          const Deprecated(this.expires);
        }
        const Object deprecated = const Deprecated("next release");
        class _Override { const _Override(); }
        const Object override = const _Override();
        class _Proxy { const _Proxy(); }
        const Object proxy = const _Proxy();

        class List<V> extends Object {}
        class Map<K, V> extends Object {}
        ''',
  'dart:html': '''
        library dart.html;
        class HtmlElement {}
        ''',
};
