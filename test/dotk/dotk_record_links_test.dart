import 'package:flutter_test/flutter_test.dart';
import 'package:kaspium_wallet/dotk/dotk_record_links.dart';

String? linkOf(String key, String value) => DotkRecordLinks.linkOf(key, value);

void main() {
  group('linkOf', () {
    test('leads a handle to its service, and a website to itself', () {
      expect(linkOf('com.twitter', 'alice'), 'https://x.com/alice');
      expect(linkOf('com.twitter', '@alice'), 'https://x.com/alice');
      expect(linkOf('com.github', '  @alice '), 'https://github.com/alice');
      expect(linkOf('org.telegram', 'alice_bob'), 'https://t.me/alice_bob');
      expect(linkOf('email', 'alice@example.org'), 'mailto:alice@example.org');
      expect(linkOf('com.discord', 'alice'), isNull);
      expect(linkOf('url', 'example.org'), 'https://example.org');
      expect(linkOf('url', 'example.org:8443/x'), 'https://example.org:8443/x');
      expect(
        linkOf('url', 'http://example.org/a?b=c'),
        'http://example.org/a?b=c',
      );
      expect(linkOf('url', 'HTTPS://a/'), 'HTTPS://a/');
      // Any other key links only an http(s) address
      expect(linkOf('avatar', 'https://a/x.png'), 'https://a/x.png');
      expect(linkOf('whatever', 'http://a/'), 'http://a/');
      expect(linkOf('avatar', 'ipfs://abc'), isNull);
      expect(linkOf('location', 'Oslo'), isNull);
    });

    test('refuses a handle that could reach past its service, and any scheme '
        'but http(s)', () {
      expect(linkOf('com.twitter', 'a/../b'), isNull);
      expect(linkOf('com.twitter', 'a b'), isNull);
      expect(linkOf('com.github', 'alice?x=1'), isNull);
      expect(linkOf('com.github', ''), isNull);
      expect(linkOf('org.telegram', 'evil.com/#'), isNull);
      expect(linkOf('email', 'not an address'), isNull);
      expect(linkOf('email', 'a@b?subject=x'), isNull);
      expect(linkOf('url', 'javascript:alert(1)'), isNull);
      expect(linkOf('url', 'ftp://a/'), isNull);
      expect(linkOf('url', 'a b.c'), isNull);
      expect(linkOf('url', '//evil'), isNull);
    });
  });
}
