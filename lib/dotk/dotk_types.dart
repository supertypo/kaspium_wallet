import 'dotk_names.dart';

class DotkNameResolution {
  final String name;
  final String display;
  final String address;

  const DotkNameResolution({
    required this.name,
    required this.display,
    required this.address,
  });

  DotkNameResolution.forName(String name, {required String address})
    : this(name: name, display: DotkName.display(name), address: address);

  @override
  bool operator ==(Object other) =>
      other is DotkNameResolution &&
      other.name == name &&
      other.display == display &&
      other.address == address;

  @override
  int get hashCode => Object.hash(name, display, address);

  @override
  String toString() => '$display -> $address';
}

/// notRegistered is the indexer's answer that the name cannot be paid: free,
/// still registering, owned by a covenant or on another network. failed says
/// nothing about the name, and unavailable means lookups are turned off.
enum DotkLookupStatus { resolved, notRegistered, failed, unavailable }

class DotkLookup {
  final DotkLookupStatus status;

  final DotkNameResolution? resolution;

  const DotkLookup(this.status, {this.resolution});

  const DotkLookup.resolved(DotkNameResolution this.resolution)
    : status = DotkLookupStatus.resolved;

  const DotkLookup.notRegistered()
    : status = DotkLookupStatus.notRegistered,
      resolution = null;

  const DotkLookup.failed()
    : status = DotkLookupStatus.failed,
      resolution = null;

  const DotkLookup.unavailable()
    : status = DotkLookupStatus.unavailable,
      resolution = null;

  @override
  String toString() => 'DotkLookup(${status.name}, $resolution)';
}
