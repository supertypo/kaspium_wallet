import 'package:flutter_test/flutter_test.dart';
import 'package:kaspium_wallet/dotk/dotk_reject.dart';
import 'package:kaspium_wallet/kaspa/kaspa.dart';

import 'dotk_fake_tx.dart';

void main() {
  test('reads the mempool wording', () {
    expect(
      DotkReject.classify(refusal('transaction 6f0a is not standard: x')),
      DotkRejectVerdict.fatal,
    );
    expect(
      DotkReject.classify(
        refusal(
          'output 0 of transaction 6f0a is already spent by transaction ab12',
        ),
      ),
      DotkRejectVerdict.stale,
    );
    expect(
      DotkReject.classify(
        refusal('transaction 6f0a is lacking a matching UTXO entry'),
      ),
      DotkRejectVerdict.transient,
    );
    expect(
      DotkReject.classify(Exception('connection reset by peer')),
      DotkRejectVerdict.unknown,
    );
    final outpoint = Outpoint(transactionId: '6f0a', index: 1);
    expect(
      DotkReject.spends(
        refusal(
          'output (6f0a, 1) already spent by transaction ab in the mempool',
        ),
        outpoint,
      ),
      isTrue,
    );
    expect(
      DotkReject.spends(
        refusal(
          'output (6f0a, 0) already spent by transaction ab in the mempool',
        ),
        outpoint,
      ),
      isFalse,
    );
    expect(
      DotkReject.spends(
        refusal(
          'output 1 of transaction 6f0a is already spent by transaction ab',
        ),
        outpoint,
      ),
      isTrue,
    );
    expect(
      DotkReject.isDuplicate(
        refusal('transaction 6f0a was already accepted by the consensus'),
      ),
      isTrue,
    );
  });
}
