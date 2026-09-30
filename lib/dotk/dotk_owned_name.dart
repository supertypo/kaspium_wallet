import '../kaspa/types.dart';
import 'dotk_records.dart';
import 'dotk_types.dart';

/// unproven: the indexer served a card the node does not back, so its records
/// are hidden. unreadable: the node holds a card whose blob does not decode or
/// exceeds [DotkRecords.blobMaxLength]; it is kept so a records edit is
/// refused rather than dropping its data.
enum DotkRecordsState { none, proven, unproven, unreadable }

/// winner: the primary name of its address. older: its card sets primary too,
/// but another name on the same address set it later.
enum DotkPrimary { none, winner, older }

/// A name one of the wallet's addresses owns, as the wallet's node proved it
class DotkOwnedName {
  /// The bare name, like `kaspa`
  final String name;

  final String address;

  final Utxo deed;

  /// The card the node proves, for a proven or an unreadable card
  final DotkCard? card;

  /// The card the indexer lists, proven or not, which a transfer must see
  final DotkCard? listedCard;
  final Utxo? cardUtxo;
  final Map<String, Object> records;
  final DotkRecordsState recordsState;
  final DotkPrimary primary;

  const DotkOwnedName({
    required this.name,
    required this.address,
    required this.deed,
    this.card,
    this.listedCard,
    this.cardUtxo,
    this.records = const {},
    this.recordsState = .none,
    this.primary = .none,
  });
}
