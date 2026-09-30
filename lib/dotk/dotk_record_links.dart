/// The record keys dotk.name labels by name. Any other key shows as it is.
enum DotkRecordPreset {
  url('url'),
  avatar('avatar'),
  description('description'),
  email('email'),
  location('location'),
  github('com.github'),
  twitter('com.twitter'),
  telegram('org.telegram'),
  discord('com.discord');

  final String key;

  const DotkRecordPreset(this.key);

  static final _byKey = {for (final preset in values) preset.key: preset};

  static DotkRecordPreset? ofKey(String key) => _byKey[key];
}

/// Where a record leads, or null where it is only text, by dotk.name's rules.
///
/// A service key holds a handle, so `com.twitter: alice` leads to x.com. The
/// value must not choose the host, add a path or script the click: a handle
/// that is not shaped like one stays text, and only http(s) is followed.
abstract class DotkRecordLinks {
  /// Letters, digits, underscore, dot and dash, so nothing reaches past the host.
  static final _handle = RegExp(r'^[A-Za-z0-9_.-]{1,64}$');

  static final _email = RegExp(r'^[^\s@?#/]+@[^\s@?#/]+$');

  static final _bareSite = RegExp(
    r'^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+(:\d+)?(/\S*)?$',
  );

  static final _web = RegExp(r'^https?://', caseSensitive: false);

  static const _services = {
    'com.twitter': 'https://x.com/',
    'com.github': 'https://github.com/',
    'org.telegram': 'https://t.me/',
  };

  static String? linkOf(String key, String value) {
    final text = value.trim();
    if (_web.hasMatch(text)) {
      return text;
    }
    final service = _services[key];
    if (service != null) {
      final handle = text.startsWith('@') ? text.substring(1) : text;
      return _handle.hasMatch(handle) ? service + handle : null;
    }
    if (key == 'email') {
      return _email.hasMatch(text) ? 'mailto:$text' : null;
    }
    if (key == 'url') {
      return _bareSite.hasMatch(text) ? 'https://$text' : null;
    }
    return null;
  }
}
