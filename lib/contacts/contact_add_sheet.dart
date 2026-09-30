import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_icons.dart';
import '../app_providers.dart';
import '../app_router.dart';
import '../dotk/dotk_lookup_text.dart';
import '../dotk/dotk_name_resolver.dart';
import '../dotk/dotk_names.dart';
import '../dotk/dotk_proven_name.dart';
import '../dotk/dotk_types.dart';
import '../kaspa/kaspa.dart';
import '../l10n/l10n.dart';
import '../util/formatters.dart';
import '../util/ui_util.dart';
import '../util/user_data_util.dart';
import '../widgets/action_buttons_wrapper.dart';
import '../widgets/address_widgets.dart';
import '../widgets/app_text_field.dart';
import '../widgets/buttons.dart';
import '../widgets/dismiss_action_buttons.dart';
import '../widgets/sheet_widget.dart';
import 'contact.dart';

const _kContactNameMaxLength = 20;

class ContactAddSheet extends ConsumerStatefulWidget {
  final String? address;

  const ContactAddSheet({super.key, this.address});

  @override
  ConsumerState<ContactAddSheet> createState() => _ContactAddSheetState();
}

class _ContactAddSheetState extends ConsumerState<ContactAddSheet> {
  final _nameFocusNode = FocusNode();
  final _addressFocusNode = FocusNode();
  final _nameController = TextEditingController();
  final _addressController = TextEditingController();

  bool _addressValid = false;
  bool _showPasteButton = true;
  bool _showNameHint = true;
  bool _showAddressHint = true;
  bool _addressValidAndUnfocused = false;
  String _nameValidationText = '';
  String _addressValidationText = '';

  /// Resolves a `.k` name typed in the address field
  late final DotkNameResolver _nameResolver;
  DotkLookup? _nameLookup;

  // Whether the validation text is about a .k name. Only such a text goes
  // away as the user types; any other stays until the next check.
  bool _nameMessage = false;
  bool _adding = false;

  @override
  void initState() {
    super.initState();

    _nameResolver = DotkNameResolver(
      service: () => ref.read(dotkServiceProvider),
      prover: () => ref.read(dotkProverProvider),
      onLookup: _onNameLookup,
      log: ref.read(loggerProvider),
    );

    // Add focus listeners
    // On name focus change
    _nameFocusNode.addListener(() {
      setState(() => _showNameHint = !_nameFocusNode.hasFocus);
    });
    // On address focus change
    _addressFocusNode.addListener(() {
      if (_addressFocusNode.hasFocus) {
        setState(() {
          _showAddressHint = false;
          _addressValidAndUnfocused = false;
        });
        _addressController.selection = .fromPosition(
          TextPosition(offset: _addressController.text.length),
        );
      } else {
        setState(() {
          _showAddressHint = true;
          final prefix = ref.read(addressPrefixProvider);
          final address = Address.tryParse(
            _addressController.text,
            expectedPrefix: prefix,
          );
          if (address != null) {
            _addressValidAndUnfocused = true;
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _nameResolver.dispose();
    _nameFocusNode.dispose();
    _addressFocusNode.dispose();
    _nameController.dispose();
    _addressController.dispose();
    super.dispose();
  }

  void _onNameLookup(String name, DotkLookup? lookup) {
    // The field may have moved on while the lookup was in flight
    if (!mounted || DotkName.tryNormalize(_addressController.text) != name) {
      return;
    }
    setState(() {
      _nameLookup = lookup;
      _nameMessage = true;
      _addressValidationText = dotkLookupText(lookup, l10nOf(context));
      final resolution = lookup?.resolution;
      if (resolution != null && _nameController.text.isEmpty) {
        final contactName = '@${resolution.name}';
        _nameController.text = contactName.length <= _kContactNameMaxLength
            ? contactName
            : contactName.substring(0, _kContactNameMaxLength);
      }
    });
  }

  void _nameTyped(String text) {
    _nameResolver.textChanged(text);
    final isName = _nameResolver.isName(text);
    if (!isName && !_nameMessage) {
      return;
    }
    setState(() {
      _nameLookup = null;
      _nameMessage = isName;
      _addressValidationText = isName ? l10nOf(context).dotkResolving : '';
    });
  }

  /// Return true if textfield should be shown, false if colorized should be shown
  bool _shouldShowTextField() {
    if (widget.address != null || _addressValidAndUnfocused) {
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final styles = ref.watch(stylesProvider);
    final l10n = l10nOf(context);

    final addressPrefix = ref.watch(addressPrefixProvider);

    final topMargin = MediaQuery.heightOf(context) * 0.14;

    return SheetWidget(
      title: l10n.addContact,
      mainWidget: Column(
        children: [
          // Enter Name Container
          AppTextField(
            topMargin: topMargin,
            padding: const .symmetric(horizontal: 30),
            focusNode: _nameFocusNode,
            controller: _nameController,
            textInputAction: widget.address != null ? .done : .next,
            hintText: _showNameHint ? l10n.contactNameHint : "",
            keyboardType: .text,
            style: styles.textStyleAppTextFieldSimple,
            inputFormatters: [
              LengthLimitingTextInputFormatter(_kContactNameMaxLength),
              ContactFormatter(),
            ],
            onSubmitted: (text) {
              final scope = FocusScope.of(context);
              if (widget.address == null) {
                final address = _addressController.text;
                final prefix = ref.read(addressPrefixProvider);
                if (!Address.isValid(address, prefix)) {
                  scope.requestFocus(_addressFocusNode);
                } else {
                  scope.unfocus();
                }
              } else {
                scope.unfocus();
              }
            },
          ),
          // Enter Name Error Container
          Container(
            margin: const .only(top: 5, bottom: 5),
            child: Text(
              _nameValidationText,
              style: styles.textStyleParagraphThinPrimary,
            ),
          ),
          // Enter Address container
          AppTextField(
            padding: !_shouldShowTextField()
                ? .symmetric(horizontal: 25, vertical: 15)
                : .zero,
            focusNode: _addressFocusNode,
            controller: _addressController,
            style: _addressValid
                ? styles.textStyleAddressText90
                : styles.textStyleAddressText60,
            inputFormatters: [
              LengthLimitingTextInputFormatter(74),
            ],
            textInputAction: .done,
            maxLines: null,
            autocorrect: false,
            hintText: _showAddressHint ? l10n.addressHint : '',
            prefixButton: TextFieldButton(
              icon: AppIcons.scan,
              onPressed: () async {
                final scanResult = await UserDataUtil.scanQrCode(context);
                if (!mounted) return;
                final data = scanResult?.code;
                if (data != null && _nameResolver.isName(data)) {
                  _addressController.text = data.trim();
                  _addressFocusNode.unfocus();
                  _nameTyped(data);
                } else if (data == null) {
                  UIUtil.showSnackbar(l10n.qrInvalidAddress);
                } else {
                  final address = Address.tryParse(
                    data,
                    expectedPrefix: addressPrefix,
                  );
                  if (mounted && address != null) {
                    _nameResolver.textChanged(address.toString());
                    setState(() {
                      _addressController.text = address.toString();
                      _addressValidationText = "";
                      _nameLookup = null;
                      _addressValid = true;
                      _addressValidAndUnfocused = true;
                    });
                    _addressFocusNode.unfocus();
                  }
                }
              },
            ),
            fadePrefixOnCondition: true,
            prefixShowFirstCondition: _showPasteButton,
            suffixButton: TextFieldButton(
              icon: AppIcons.paste,
              onPressed: () async {
                if (!_showPasteButton) {
                  return;
                }
                String? data = await UserDataUtil.getClipboardText(.ADDRESS);
                if (data != null) {
                  _nameResolver.textChanged(data);
                  setState(() {
                    _addressValid = true;
                    _showPasteButton = false;
                    _addressController.text = data;
                    _addressValidationText = '';
                    _nameLookup = null;
                    _addressValidAndUnfocused = true;
                  });
                  _addressFocusNode.unfocus();
                } else {
                  setState(() {
                    _showPasteButton = true;
                    _addressValid = false;
                  });
                }
              },
            ),
            fadeSuffixOnCondition: true,
            suffixShowFirstCondition: _showPasteButton,
            onChanged: (text) {
              final address = Address.tryParse(
                text,
                expectedPrefix: addressPrefix,
              );
              if (address != null) {
                _nameResolver.textChanged(text);
                setState(() {
                  _addressValid = true;
                  _showPasteButton = false;
                  _addressValidationText = '';
                  _nameLookup = null;
                  _addressController.text = address.toString();
                });
                _addressFocusNode.unfocus();
              } else {
                setState(() {
                  _showPasteButton = true;
                  _addressValid = false;
                });
                _nameTyped(text);
              }
            },
            overrideTextFieldWidget: !_shouldShowTextField()
                ? GestureDetector(
                    onTap: () {
                      if (widget.address != null) {
                        return;
                      }
                      setState(() {
                        _addressValidAndUnfocused = false;
                      });
                      Future.delayed(Duration(milliseconds: 50), () {
                        if (!context.mounted) return;
                        FocusScope.of(context).requestFocus(_addressFocusNode);
                      });
                    },
                    child: AddressThreeLineText(
                      address: widget.address != null
                          ? widget.address!
                          : _addressController.text,
                    ),
                  )
                : null,
          ),
          // Enter Address Error Container
          Container(
            margin: const .only(top: 5, bottom: 5, left: 30, right: 30),
            child: _nameLookup?.resolution != null
                ? DotkProvenName(
                    _addressValidationText,
                    style: styles.textStyleParagraphThinPrimary,
                  )
                : Text(
                    _addressValidationText,
                    textAlign: .center,
                    style: styles.textStyleParagraphThinPrimary,
                  ),
          ),
        ],
      ),
      bottomWidget: ActionButtonsWrapper(
        buttons: [
          PrimaryButton(
            title: l10n.addContact,
            disabled: _adding,
            onPressed: _addContact,
          ),
          const CancelActionButton(),
        ],
      ),
    );
  }

  Future<void> _addContact() async {
    if (_adding) return;
    // A .k name resolves again first, which can take a moment
    final resolving = _nameResolver.isName(_addressController.text);
    if (resolving) setState(() => _adding = true);
    final isValid = await _validateForm();
    if (resolving && mounted) setState(() => _adding = false);
    if (!isValid || !mounted) {
      return;
    }
    final newContact = Contact(
      name: _nameController.text,
      address:
          widget.address ??
          (_nameResolver.isName(_addressController.text)
              ? _nameLookup?.resolution?.address
              : null) ??
          _addressController.text,
    );
    final contacts = ref.read(contactsProvider);
    await contacts.addContact(newContact);
    final context = this.context;
    if (!context.mounted) return;
    final l10n = l10nOf(context);
    UIUtil.showSnackbar(l10n.contactAdded(newContact.name));
    appRouter.pop(context);
  }

  Future<bool> _validateForm() async {
    final l10n = l10nOf(context);
    final prefix = ref.read(addressPrefixProvider);
    bool isValid = true;
    // Address Validations
    // Don't validate address if it came pre-filled in
    if (widget.address == null) {
      final text = _addressController.text;
      if (text.isEmpty) {
        isValid = false;
        setState(() {
          _nameMessage = false;
          _addressValidationText = l10n.addressMising;
        });
      } else if (_nameResolver.isName(text)) {
        // Resolve again: the name may have moved since the field's lookup
        final lookup = await _nameResolver.resolveForSend(
          text,
          current: () => _addressController.text,
        );
        final address = lookup?.resolution?.address;
        if (!mounted) return false;
        if (address == null) {
          isValid = false;
          setState(() {
            _nameLookup = lookup;
            _nameMessage = true;
            _addressValidationText = lookup == null
                ? l10n.dotkLookupFailed
                : dotkLookupError(lookup.status, l10n);
          });
        } else if (ref
            .read(contactsProvider)
            .contactExistsWithAddress(address)) {
          isValid = false;
          // An error, so not drawn as the proven name it came from
          setState(() {
            _nameLookup = null;
            _addressValidationText = l10n.contactExists;
          });
        }
      } else if (Address.tryParse(text, expectedPrefix: prefix) == null) {
        isValid = false;
        setState(() {
          _nameMessage = false;
          _addressValidationText = l10n.invalidAddress;
        });
      } else {
        _addressFocusNode.unfocus();
        bool addressExists = ref
            .read(contactsProvider)
            .contactExistsWithAddress(_addressController.text);
        if (addressExists) {
          setState(() {
            isValid = false;
            _addressValidationText = l10n.contactExists;
          });
        }
      }
    }
    // Name Validations
    if (_nameController.text.isEmpty) {
      isValid = false;
      setState(() {
        _nameValidationText = l10n.contactNameMissing;
      });
    } else {
      bool nameExists = ref
          .read(contactsProvider)
          .contactExistsWithName(_nameController.text);
      if (nameExists) {
        setState(() {
          isValid = false;
          _nameValidationText = l10n.contactExists;
        });
      }
    }
    return isValid;
  }
}
