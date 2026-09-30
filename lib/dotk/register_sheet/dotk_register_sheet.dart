import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../app_styles.dart';
import '../../kaspa/kaspa.dart';
import '../../l10n/l10n.dart';
import '../../util/ui_util.dart';
import '../../wallet_address/address_selection_sheet.dart';
import '../../wallet_address/wallet_address.dart';
import '../../widgets/action_buttons_wrapper.dart';
import '../../widgets/address_widgets.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/buttons.dart';
import '../../widgets/sheet_util.dart';
import '../../widgets/sheet_widget.dart';
import '../dotk_error_text.dart';
import '../dotk_names.dart';
import '../dotk_registry.dart';
import '../dotk_sheet_parts.dart';
import '../dotk_tx_assemble.dart';
import '../dotk_tx_providers.dart';
import '../dotk_types.dart';
import 'dotk_name_formatter.dart';
import 'dotk_register_confirm_sheet.dart';
import 'dotk_register_progress_sheet.dart';

/// What the registration plan funds from, which leaves covenant coins out
BigInt _spendable(Iterable<Utxo> utxos) => utxos
    .where((utxo) => utxo.utxoEntry.covenantId == null)
    .fold(BigInt.zero, (total, utxo) => total + utxo.utxoEntry.amount);

/// invalid: the registry cannot hold the name, as the indexer answers
enum _Availability { none, checking, available, registered, invalid, failed }

/// Finds a free name and its price, and picks the address that will own it
class DotkRegisterSheet extends ConsumerStatefulWidget {
  /// A name to start with, as when a failed registration is started again
  final String? initialName;
  final String? initialOwner;

  const DotkRegisterSheet({super.key, this.initialName, this.initialOwner});

  @override
  ConsumerState<DotkRegisterSheet> createState() => _DotkRegisterSheetState();
}

class _DotkRegisterSheetState extends ConsumerState<DotkRegisterSheet> {
  static const _debounce = Duration(milliseconds: 400);

  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  Timer? _timer;
  int _generation = 0;
  _Availability _availability = .none;
  DotkKeyInfo? _key;
  WalletAddress? _owner;
  bool _planning = false;

  @override
  void initState() {
    super.initState();
    final name = widget.initialName;
    if (name != null) {
      _controller.text = name;
      _check(name);
    }
    final owner = widget.initialOwner;
    if (owner != null) {
      _owner = ref.read(addressNotifierProvider).getAddress(owner);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _changed(String text) {
    _timer?.cancel();
    _generation += 1;
    setState(() {
      _key = null;
      _availability = DotkName.isValid(text) ? .checking : .none;
    });
    if (DotkName.isValid(text)) {
      _timer = Timer(_debounce, () => _check(text));
    }
  }

  Future<void> _check(String name) async {
    final generation = ++_generation;
    setState(() => _availability = .checking);
    DotkKeyInfo? key;
    var failed = false;
    try {
      key = await ref.read(dotkServiceProvider).keyInfo(name);
    } catch (e, st) {
      ref
          .read(loggerProvider)
          .w('Failed to check $name', error: e, stackTrace: st);
      failed = true;
    }
    if (!mounted || generation != _generation) {
      return;
    }
    setState(() {
      _key = key;
      _availability = failed
          ? .failed
          : key == null
          ? .invalid
          : key.free
          ? .available
          : .registered;
    });
  }

  Future<void> _chooseOwner() async {
    final selected = await Sheets.showAppHeightNineSheet<WalletAddress>(
      context: context,
      theme: ref.read(themeProvider),
      fullHeight: true,
      widget: const AddressSelectionSheet(showNewAddressButton: false),
    );
    if (selected != null && mounted) {
      setState(() => _owner = selected);
    }
  }

  Future<void> _continue(String name, WalletAddress owner) async {
    final service = ref.read(dotkTxServiceProvider);
    final key = _key;
    if (service == null || key == null || _planning) {
      return;
    }
    // A registration of the name that is under way or stopped is resumed or
    // dismissed there, not started again
    final existing = ref.read(dotkRegistrationProvider).entry(name);
    if (existing != null && existing.stage != .done) {
      Sheets.showAppHeightNineSheet(
        context: context,
        theme: ref.read(themeProvider),
        widget: DotkRegisterProgressSheet(name: name),
      );
      return;
    }
    final l10n = l10nOf(context);
    setState(() => _planning = true);
    try {
      final plan = await service.planRegistration(
        name: name,
        owner: owner.address,
        gapLo: key.gapLo!,
        gapHi: key.gapHi!,
      );
      if (!mounted) return;
      Sheets.showAppHeightNineSheet(
        context: context,
        theme: ref.read(themeProvider),
        widget: DotkRegisterConfirmSheet(plan: plan),
      );
    } catch (e, st) {
      ref
          .read(loggerProvider)
          .w('Registration plan failed', error: e, stackTrace: st);
      ref.read(hapticUtilProvider).error();
      final symbol = ref.read(kasSymbolProvider);
      final balance = _spendable(ref.read(dotkFundingUtxosProvider));
      UIUtil.showSnackbar(
        e is DotkInsufficientFundsError && e is! DotkChangeTooSmallError
            // The shortfall, since what the error counts can include the
            // registry's own inputs
            ? l10n.dotkNotEnoughKas(
                dotkAmount(balance + e.needed - e.available, symbol),
                dotkAmount(balance, symbol),
              )
            : dotkErrorText(e, l10n),
      );
    } finally {
      if (mounted) setState(() => _planning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(themeProvider);
    final styles = ref.watch(stylesProvider);
    final l10n = l10nOf(context);

    final registry = DotkRegistry.forNetworkId(ref.watch(networkIdProvider));
    final owner = _owner ?? ref.watch(receiveAddressProvider);
    final balance = _spendable(ref.watch(dotkFundingUtxosProvider));
    final symbol = ref.watch(kasSymbolProvider);
    String kas(BigInt raw) => dotkAmount(raw, symbol);

    final name = _controller.text;
    final display = DotkName.display(name);
    final params = registry?.params;
    final locked = params == null ? BigInt.zero : params.bond + params.gapValue;
    BigInt priceOf(String bare) =>
        params == null ? BigInt.zero : params.feeForName(bare) + locked;
    final price = name.isEmpty ? null : priceOf(name);
    // A lower bound, since the fees depend on the coins and the market. The
    // plan behind Continue prices them and refuses a shortfall.
    final needed = price == null
        ? null
        : price + DotkRegistration.defaultBuffer;
    final affordable = needed == null || balance >= needed;

    String? line;
    Color? lineColor;
    if (name.isNotEmpty && name.length > DotkName.maxLength) {
      line = l10n.dotkNameTooLong;
      lineColor = theme.danger;
    } else if (name.endsWith('.')) {
      // The dot of a `.k` still being typed, which the formatter drops
    } else if (name.isNotEmpty && !DotkName.isValid(name)) {
      line = l10n.dotkInvalidName;
      lineColor = theme.danger;
    } else {
      switch (_availability) {
        case .none:
          break;
        case .checking:
          line = l10n.dotkChecking(display);
          lineColor = theme.text60;
        case .available when !affordable:
          line = l10n.dotkNotEnoughKas(kas(needed), kas(balance));
          lineColor = theme.danger;
        case .available:
          line = l10n.dotkAvailable(display);
          lineColor = theme.dotkAccent;
        case .registered:
          line = l10n.dotkRegistered(display);
          lineColor = theme.danger;
        case .invalid:
          line = l10n.dotkInvalidName;
          lineColor = theme.danger;
        case .failed:
          line = l10n.dotkAvailabilityFailed(display);
          lineColor = theme.warning;
      }
    }
    final ready =
        _availability == .available &&
        affordable &&
        !_planning &&
        owner != null;

    return Padding(
      padding: .only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SheetWidget(
        title: l10n.dotkRegisterName,
        mainWidget: ListView(
          padding: const .only(bottom: 16),
          children: [
            AppTextField(
              topMargin: 6,
              controller: _controller,
              focusNode: _focusNode,
              hintText: l10n.dotkNameHint,
              textAlign: .center,
              autocorrect: false,
              enableSuggestions: false,
              smartDashesType: .disabled,
              smartQuotesType: .disabled,
              keyboardType: .visiblePassword,
              textInputAction: .done,
              style: styles.textStyleAppTextField,
              inputFormatters: [
                DotkNameFormatter(),
                LengthLimitingTextInputFormatter(DotkName.maxLength + 1),
              ],
              onChanged: _changed,
            ),
            if (line != null)
              Padding(
                padding: const .fromLTRB(40, 8, 40, 0),
                child: Semantics(
                  // A check's answer is read out, not each keystroke
                  liveRegion:
                      _availability != .none && _availability != .checking,
                  child: Text(
                    line,
                    textAlign: .center,
                    style: styles.textStyleSettingItemSubheader.copyWith(
                      fontSize: AppFontSizes.small,
                      color: lineColor,
                    ),
                  ),
                ),
              ),
            if (_availability == .available && price != null) ...[
              const SizedBox(height: 14),
              Text(
                kas(price),
                textAlign: .center,
                style: styles.textStyleHeader,
              ),
              Text(
                name.length >= 5
                    ? l10n.dotkPriceForLong
                    : l10n.dotkPriceFor(name.length),
                textAlign: .center,
                style: styles.textStyleSettingItemSubheader,
              ),
            ],
            Padding(
              padding: const .symmetric(horizontal: 28),
              child: Column(
                crossAxisAlignment: .stretch,
                children: [
                  DotkSection(l10n.dotkOwner),
                  Container(
                    padding: const .directional(
                      start: 12,
                      top: 6,
                      end: 4,
                      bottom: 6,
                    ),
                    decoration: BoxDecoration(
                      color: theme.text05,
                      border: .all(color: theme.text10),
                      borderRadius: .circular(12),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: .start,
                            children: [
                              Text(
                                owner?.name ?? '',
                                style: styles.textStyleSettingItemHeader,
                              ),
                              if (owner != null)
                                AddressOneLineText(
                                  address: owner.encoded,
                                  type: .PRIMARY60,
                                ),
                            ],
                          ),
                        ),
                        TextButton(
                          onPressed: _chooseOwner,
                          style: TextButton.styleFrom(
                            foregroundColor: theme.dotkAccent,
                            minimumSize: const Size(48, 48),
                          ),
                          child: Text(l10n.dotkChangeOwner.toUpperCase()),
                        ),
                      ],
                    ),
                  ),
                  DotkSection(l10n.dotkPrices),
                  DotkBox(
                    children: [
                      for (var length = 1; length <= 4; length++)
                        DotkValueRow(
                          l10n.dotkPriceLength(length),
                          kas(priceOf('a' * length)),
                        ),
                      DotkValueRow(
                        l10n.dotkPriceLengthLong,
                        kas(priceOf('aaaaa')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        bottomWidget: ActionButtonsWrapper(
          buttons: [
            PrimaryButton(
              title: l10n.doContinue,
              disabled: !ready,
              onPressed: ready ? () => _continue(name, owner) : null,
            ),
          ],
        ),
      ),
    );
  }
}
