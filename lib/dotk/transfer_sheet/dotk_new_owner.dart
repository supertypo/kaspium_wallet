import '../../kaspa/kaspa.dart';

/// Why a text cannot be the new owner of a name
enum DotkNewOwnerError {
  /// Neither a Kaspa address nor a .k name
  notAddress,

  /// An address for another network
  otherNetwork,

  /// A script address, which no key of this wallet's kind can own a name as
  scriptAddress,

  /// The name's current owner
  sameOwner,
}

/// The address [text] names as a new owner, or why it cannot be one. A .k
/// name or a contact is resolved before this is asked.
(Address?, DotkNewOwnerError?) parseNewOwner(
  String text, {
  required AddressPrefix prefix,
  required String owner,
}) {
  final Address address;
  try {
    address = Address.decodeAddress(text.trim());
  } catch (_) {
    return (null, .notAddress);
  }
  if (!address.isForPrefix(prefix)) {
    return (null, .otherNetwork);
  }
  final error = address.when<DotkNewOwnerError?>(
    publicKey: (_, _) => null,
    pubKeyECDSA: (_, _) => null,
    scriptHash: (_, _) => .scriptAddress,
  );
  if (error != null) {
    return (null, error);
  }
  if (address.encoded == owner) {
    return (null, .sameOwner);
  }

  return (address, null);
}
