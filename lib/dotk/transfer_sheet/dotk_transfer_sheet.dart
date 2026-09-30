import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_icons.dart';
import '../../app_providers.dart';
import '../../app_styles.dart';
import '../../kaspa/kaspa.dart';
import '../../l10n/l10n.dart';
import '../../util/ui_util.dart';
import '../../util/user_data_util.dart';
import '../../wallet_address/address_selection_sheet.dart';
import '../../wallet_address/wallet_address.dart';
import '../../widgets/action_buttons_wrapper.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/buttons.dart';
import '../../widgets/sheet_util.dart';
import '../../widgets/sheet_widget.dart';
import '../dotk_error_text.dart';
import '../dotk_lookup_text.dart';
import '../dotk_name_resolver.dart';
import '../dotk_names.dart';
import '../dotk_owned_name.dart';
import '../dotk_proven_name.dart';
import '../dotk_sheet_parts.dart';
import '../dotk_tx_providers.dart';
import '../dotk_tx_service.dart';
import '../dotk_types.dart';
import 'dotk_new_owner.dart';
import 'dotk_transfer_confirm_sheet.dart';

/// Picks the new owner of a name: an address, a .k name, an @contact, or one
/// of the wallet's own addresses
class DotkTransferSheet extends ConsumerStatefulWidget {
  final DotkOwnedName name;

  const DotkTransferSheet({super.key, required this.name});

  @override
  ConsumerState<DotkTransferSheet> createState() => _DotkTransferSheetState();
}

const _kTypingPause = Duration(seconds: 1);

class _DotkTransferSheetState extends ConsumerState<DotkTransferSheet> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  late final DotkNameResolver _resolver;
  DotkLookup? _lookup;
  bool _planning = false;

  @override
  void initState() {
    super.initState();
    _resolver = DotkNameResolver(
      service: () => ref.read(dotkServiceProvider),
      prover: () => ref.read(dotkProverProvider),
      onLookup: _onLookup,
      log: ref.read(loggerProvider),
    );
    // "Not an address" waits until the user leaves the field
    _focusNode.addListener(_focusChanged);
  }

  void _focusChanged() => setState(() {
    if (!_focusNode.hasFocus) _typedAt = null;
  });

  /// When the user last typed, until a paste, a scan or leaving the field
  DateTime? _typedAt;
  String _lastText = '';
  Timer? _typingPause;

  /// A partial address is not an error while the user is still typing it:
  /// the keyboard is up, or a hardware keyboard was used a moment ago. Back
  /// on Android hides the keyboard but keeps the focus.
  bool _typing(BuildContext context) {
    final typedAt = _typedAt;
    return typedAt != null &&
        _focusNode.hasFocus &&
        (MediaQuery.viewInsetsOf(context).bottom > 0 ||
            DateTime.now().difference(typedAt) < _kTypingPause);
  }

  @override
  void dispose() {
    _typingPause?.cancel();
    _resolver.dispose();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onLookup(String name, DotkLookup? lookup) {
    if (!mounted || DotkName.tryNormalize(_controller.text) != name) {
      return;
    }
    setState(() => _lookup = lookup);
  }

  void _typed(String text) {
    // Several characters at once are a paste from the text menu, which
    // reads a payment URI as the paste button does
    final pasted = text.length - _lastText.length > 1;
    if (pasted && _ownerText(text.trim()) != text) {
      _setText(_ownerText(text.trim()));
      return;
    }
    _typedAt = pasted ? null : DateTime.now();
    _typingPause?.cancel();
    _typingPause = Timer(_kTypingPause, () {
      if (mounted) setState(() {});
    });
    _changed(text);
  }

  void _changed(String text) {
    _lastText = text;
    _resolver.textChanged(text);
    setState(() => _lookup = null);
  }

  void _setText(String text) {
    _typedAt = null;
    _controller.text = text;
    _controller.selection = .collapsed(offset: text.length);
    _changed(text);
  }

  Future<void> _paste() async {
    final text = (await UserDataUtil.getClipboardText(.RAW))?.trim();
    if (text != null && text.isNotEmpty && mounted) {
      _setText(_ownerText(text));
    }
  }

  Future<void> _scan() async {
    final result = await UserDataUtil.scanQrCode(context);
    final code = result?.code?.trim();
    if (code == null || !mounted) {
      return;
    }
    _setText(_ownerText(code));
  }

  /// A payment URI names its address, and a name or an address stands alone
  String _ownerText(String text) {
    final prefix = ref.read(addressPrefixProvider);
    return KaspaUri.tryParse(text, prefix: prefix)?.address.encoded ?? text;
  }

  Future<void> _chooseOwn() async {
    final selected = await Sheets.showAppHeightNineSheet<WalletAddress>(
      context: context,
      theme: ref.read(themeProvider),
      fullHeight: true,
      widget: const AddressSelectionSheet(showNewAddressButton: false),
    );
    if (selected != null && mounted) {
      _setText(selected.encoded);
    }
  }

  /// The text as an address: a proven name's, a contact's, or the text
  String? _addressText() {
    final text = _controller.text.trim();
    if (DotkName.isName(text)) {
      return _resolver.resolvedFor(text)?.address;
    }
    if (text.startsWith('@')) {
      return ref.read(contactsProvider).getContactWithName(text)?.address;
    }
    return text;
  }

  /// The name as the wallet last read it, which a rescan may have changed
  DotkOwnedName _current() =>
      ref.read(dotkWalletNamesProvider).ownedName(widget.name.name) ??
      widget.name;

  Future<void> _continue(Address to, String target) async {
    final service = ref.read(dotkTxServiceProvider);
    if (service == null || _planning) {
      return;
    }
    final l10n = l10nOf(context);
    setState(() => _planning = true);
    final name = _current();
    try {
      final plan = await service.planTransfer(
        name: name.name,
        from: Address.decodeAddress(name.address),
        to: to,
        card: name.listedCard,
      );
      if (!mounted) return;
      Sheets.showAppHeightNineSheet(
        context: context,
        theme: ref.read(themeProvider),
        widget: DotkTransferConfirmSheet(
          name: name,
          plan: plan,
          target: target,
        ),
      );
    } catch (e, st) {
      ref
          .read(loggerProvider)
          .w('Transfer plan failed', error: e, stackTrace: st);
      if (e is DotkSettlingError) {
        // The next try reads the name once the indexer has caught up
        unawaited(
          ref.read(dotkWalletNamesProvider).awaitName(name.name, name.address),
        );
      }
      ref.read(hapticUtilProvider).error();
      UIUtil.showSnackbar(dotkErrorText(e, l10n));
    } finally {
      if (mounted) setState(() => _planning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(themeProvider);
    final styles = ref.watch(stylesProvider);
    final l10n = l10nOf(context);

    final prefix = ref.watch(addressPrefixProvider);
    final addresses = ref.watch(addressNotifierProvider);
    final following = ref
        .watch(dotkWalletNamesProvider)
        .isFollowing(widget.name.name);
    final name = _current();
    final display = DotkName.display(name.name);
    final owner = addresses.getAddress(name.address);

    final text = _controller.text.trim();
    final isName = DotkName.isName(text);
    final addressText = _addressText();

    Address? to;
    String? line;
    var lineProven = false;
    var lineError = false;
    var outside = false;
    var target = '';
    final typing = _typing(context);
    if (text.isEmpty) {
      line = null;
    } else if (isName && addressText == null) {
      line = dotkLookupText(_lookup, l10n);
      lineError = _lookup != null;
    } else if (addressText == null) {
      if (!typing) {
        line = text.startsWith('@')
            ? l10n.contactInvalid
            : l10n.dotkErrorNotAddress;
        lineError = true;
      }
    } else {
      final (address, error) = parseNewOwner(
        addressText,
        prefix: prefix,
        owner: name.address,
      );
      // A partial address is left alone while it is being typed
      if (error != null && !(error == .notAddress && typing)) {
        line = switch (error) {
          .notAddress => l10n.dotkErrorNotAddress,
          .otherNetwork => l10n.dotkErrorOtherNetwork,
          .scriptAddress => l10n.dotkErrorScriptAddress,
          .sameOwner => l10n.dotkErrorSameOwner(display),
        };
        lineError = true;
      } else if (address != null) {
        final own = addresses.getAddress(address.encoded);
        outside = own == null;
        // An own address gets the records, which must be the proven ones
        if (!outside && name.recordsState == .unproven) {
          line = l10n.dotkRecordsConfirming;
          lineError = true;
        } else if (isName) {
          to = address;
          final resolution = _resolver.resolvedFor(text)!;
          target = resolution.display;
          // The resolution stands while an edit keeps the same name
          line = dotkLookupText(
            _lookup ?? DotkLookup.resolved(resolution),
            l10n,
          );
          lineProven = true;
        } else {
          to = address;
          if (text.startsWith('@')) {
            target = text;
            line = text;
          } else if (own != null) {
            target = own.name;
            line = l10n.dotkThisWallet(own.name);
          } else {
            target = address.encoded;
          }
        }
      }
    }

    final lineStyle = styles.textStyleSettingItemSubheader.copyWith(
      fontSize: AppFontSizes.small,
      color: lineError ? theme.danger : theme.dotkAccent,
    );

    // The keyboard pushes the sheet up, so its button stays in reach
    return Padding(
      padding: .only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SheetWidget(
        title: l10n.transfer,
        mainWidget: ListView(
          padding: const .only(bottom: 16),
          children: [
            Center(
              child: DotkProvenName(
                display,
                style: styles.textStyleHeader.copyWith(color: theme.dotkAccent),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              l10n.dotkOwnedBy(owner?.name ?? name.address),
              style: styles.textStyleSettingItemSubheader,
              textAlign: .center,
            ),
            const SizedBox(height: 18),
            Padding(
              padding: .symmetric(
                horizontal: MediaQuery.widthOf(context) * 0.105 + 8,
              ),
              child: Text(
                l10n.dotkNewOwner.toUpperCase(),
                style: styles.textStyleSettingItemSubheader.copyWith(
                  fontWeight: .w700,
                  letterSpacing: 0.8,
                ),
              ),
            ),
            AppTextField(
              topMargin: 6,
              controller: _controller,
              focusNode: _focusNode,
              hintText: l10n.dotkNewOwnerHint,
              maxLines: null,
              autocorrect: false,
              enableSuggestions: false,
              smartDashesType: .disabled,
              smartQuotesType: .disabled,
              keyboardType: .text,
              textInputAction: .done,
              style: styles.textStyleAddressText90,
              // A pasted payment URI is cut to its address after this
              inputFormatters: [LengthLimitingTextInputFormatter(2000)],
              prefixButton: TextFieldButton(
                icon: AppIcons.scan,
                onPressed: _scan,
              ),
              suffixButton: TextFieldButton(
                icon: AppIcons.paste,
                onPressed: _paste,
              ),
              onChanged: _typed,
            ),
            if (line != null)
              Padding(
                padding: const .fromLTRB(40, 8, 40, 0),
                child: Semantics(
                  // Answers are read out, not "resolving"
                  liveRegion: !(isName && _lookup == null && !lineProven),
                  child: lineProven
                      ? DotkProvenName(line, style: lineStyle)
                      : Text(line, style: lineStyle, textAlign: .center),
                ),
              ),
            if (outside && to != null)
              Padding(
                padding: const .fromLTRB(30, 14, 30, 0),
                child: DotkNotice(
                  l10n.dotkOutsideWallet(display),
                  kind: .danger,
                ),
              ),
            Padding(
              padding: const .fromLTRB(30, 16, 30, 0),
              child: Center(
                child: TextButton(
                  onPressed: _chooseOwn,
                  style: TextButton.styleFrom(
                    foregroundColor: theme.dotkAccent,
                    minimumSize: const Size(48, 48),
                  ),
                  child: Text(l10n.dotkChooseMyAddress.toUpperCase()),
                ),
              ),
            ),
          ],
        ),
        bottomWidget: ActionButtonsWrapper(
          buttons: [
            PrimaryButton(
              title: l10n.doContinue,
              disabled: to == null || _planning || following,
              onPressed: to == null || following
                  ? null
                  : () => _continue(to!, target),
            ),
          ],
        ),
      ),
    );
  }
}
