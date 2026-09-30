import '../l10n/l10n.dart';
import 'dotk_tx.dart';
import 'dotk_tx_assemble.dart';
import 'dotk_tx_service.dart';

/// What the user reads when a .k name action fails. The details go to the
/// log, since they name inputs and scripts.
String dotkErrorText(Object error, AppLocalizations l10n) => switch (error) {
  DotkWatchOnlyError() => l10n.dotkWatchOnly,
  DotkInsufficientFundsError() => l10n.dotkErrorFunds,
  DotkSettlingError() => l10n.dotkRecordsConfirming,
  DotkStaleError() => l10n.dotkErrorStale,
  DotkFeeRoseError() => l10n.dotkErrorFeeRose,
  DotkFeeCeilingError() || DotkMassError() => l10n.dotkErrorTooLarge,
  // A record blob the edits cannot read, or an odd answer from the indexer
  DotkTxError() || FormatException() => l10n.dotkErrorGeneric,
  _ => l10n.dotkErrorNetwork,
};
