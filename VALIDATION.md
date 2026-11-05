# Validation record

Validated on this Apple silicon Mac, macOS 26.6.2, with Xcode 27.0 / Swift 6.4.

## Passed

- Release Xcode build, deployment target macOS 14, arm64.
- 39 automated tests with zero failures. Includes generated XLSX workbooks (1900/1904 dates, zero-padded identifiers, Chinese text), quoted/multiline CSV, formula-safe export, amounts and dates, bank/card profile scaffolds, column positions and multiline rows, image-only PDF OCR, password-protected PDF extraction, rule conflicts and overrides, repeated imports, allocation limits, partial/combined payments, reversal/rollback, reconciliation, persistence, and backup tamper detection.
- Packaged Release app `--self-check` passed inside its sandbox, including saving, reading, updating, and deleting a synthetic Keychain credential: local PDF extraction, Vision OCR, SwiftData persistence, invoice allocations, CSV export, and backup restore.
- Installed app signature verified with `codesign --verify --deep --strict`.
- Version 0.2 Release entitlements contain App Sandbox, user-selected read/write files, and outbound network access for optional DeepSeek requests. No CloudKit or debugger entitlement. AI assistance defaults off.
- Native UI launched with synthetic data in the isolated demo workspace; statement list, transaction review state, and source PDF were inspected. The statement list layout was subsequently made more compact and compiled in the final Release.

Installed app: `/Users/Thomas/Applications/Statement Manager.app`.

## DeepSeek integration (version 0.2)

- Official model `deepseek-v4-flash`, fixed HTTPS endpoint, JSON mode and disabled thinking.
- Nine additional mocked API tests passed: request fields/data minimization, input/key rejection, response validation, model access, no model substitution, sanitized HTTP errors, full request/response flow, cancellation, and redirect blocking.
- Production Keychain access was tested in the signed sandboxed app with a temporary synthetic key, then removed.
- No real API key was read or saved by this implementation session, and no live DeepSeek API request or paid completion was made. The in-app Test connection checks the user's saved key after they supply it.
- The optional feature sends only explicitly requested transaction context, as disclosed in AI Settings. PDF extraction, OCR, and imports remain local.

## Still required before production acceptance

- Two periods for every actual HSBC/Bank of China bank/card layout in use. Compare all dates, signs, amounts, references, transaction counts, and balances against manually checked originals. Profiles remain visibly unvalidated.
- A representative invoice spreadsheet and your real categorization rules. Measure category precision against an independently reviewed pilot (target at least 95% among automatically assigned categories).
- User-specific FileVault and encrypted Time Machine configuration. No system security settings were changed.
- Testing on older supported macOS versions or other hardware; only this Mac was tested.
- Developer ID signing/notarization before distribution to other Macs. The installed local build is ad-hoc signed.

No real financial documents were used as test fixtures. Synthetic UI data lives separately from the normal business workspace. Quit the demo preview before opening the installed app normally.

## Empty-table fix (version 0.3)

- Reproduced the installed app showing zero rows for the user's imported HSBC PDF.
- Verified the updated local parser extracts 48 rows (23 deposits, 25 withdrawals), matching the PDF's printed transaction count and closing balance. Detected the statement date from the PDF. No private descriptions or account identifiers were copied into source or test fixtures.
- Added synthetic tests for date/count detection and empty-import recovery, including refusal to replace edited rows or recover mismatched totals/counts.
- Installed and reopened version 0.3. The actual UI now displays the 48-row table with Date, Description, HKD, and Category columns; balance is matched and all 48 rows remain unreviewed.
- Automatic recovery is restricted to empty saved imports with matching PDF hash, printed transaction count, and balances. Recovery is undoable. No AI API call was needed.
- Import now reads the PDF automatically, suggests its date and a uniquely matching bank account, previews a table, and requires an explicit manual-entry choice before saving a zero-row result.

## Transaction direction, types, and references update

- All 41 automated tests pass, including signed classifications, leading-zero references, legacy enum decoding, card direction normalization, and preservation of manual/reviewed entries.
- Release build and sandboxed synthetic end-to-end self-check pass. Updated application installed.
- The user's transaction editor was open, so it was left undisturbed. The updated table requires saving/cancelling that edit and restarting the app; live UI verification of the new columns remains pending.

## Version 0.4 custom items and payee column

- 43 automated tests pass. Added tests cover custom names and Chinese categories, duplicate/blank rejection, workspace JSON round-trip, loading legacy workspaces without the new optional fields, rule conflicts, preservation of manual labels, and CSV type/payee/category values.
- Release compilation succeeded. Add Type and Add Category are shared between transaction and rule editors. Payee / Client is included in both transaction tables.
- Sandboxed self-check passed (PDF/OCR, persistence, allocations, CSV, backup restore, temporary synthetic Keychain access). Final 0.4 build installed and reopened. Live UI verified Payee / Client column and both Add type / Add category dialogs. Corrected a first-presentation sheet-state issue found during UI testing. Preview dialogs were cancelled without changing user transactions or creating test items.

## Version 0.4.1: six review findings fixed

- Restored required App Sandbox/user-selected file/network-client entitlements. Release build and signature verification pass.
- Recovered the 34 original substantive tests from Git into Tests/StatementManagerTests; added 14 regression tests. Both SwiftPM and Xcode Test execute all 48 tests with zero failures. The project generator preserves the native test target and Test action.
- Tested adjacent-page B/F and C/F date continuation, final-balance boundaries, decimal figures inside descriptions, reference label normalization with preserved leading zeros/prefixes, trimmed/case-insensitive category duplicates, custom type/export/rule behavior, and empty-import recovery safeguards.
- Packaged sandboxed self-check passes for PDF/OCR, SwiftData persistence, allocations, CSV, backups, and temporary synthetic Keychain access. Release entitlement inspection confirms sandboxing, user-selected read/write access, and outbound client access for optional AI.
- Installed 0.4.1 locally. Existing transactions and PDFs were not reparsed or replaced. Previously skipped rows/truncated descriptions need explicit re-extraction with review of the replacement warning. No live API requests were made.

## Version 0.5: software review fixes (not yet built or tested on a Mac)

These changes were made in a Linux environment without the macOS SDK, so neither the app nor the test suite has been compiled or run yet. Before installing, run `./scripts/test.sh` and the Release build on the Mac, then `--self-check`.

- DeepSeek model changed from `deepseek-flash` to the current `deepseek-v4-flash`. Confirm with **Test connection** using your saved key.
- Multi-file PDF import now resets the period start/end and preview for each file, so an undetected statement date no longer inherits the previous file's period.
- Duplicate flags are recomputed in linear time and cleared when the matching row disappears (statement rollback, re-import, row removal, or an edit that resolves the match). Edits and removals only clear flags, so a row the user confirmed as separate is not re-flagged.
- Invoice register amounts with Excel floating-point noise are rounded to the cent; genuine extra decimals are still rejected.
- Reports: bank-only Money received / Money paid, with card charges and card repayments/credits shown separately to avoid double-counting card bill payments.
- Background rule application, empty-import recovery, and statement import re-apply to the current workspace if it changed meanwhile, so concurrent edits are not overwritten.
- Password-protected originals can be previewed: the import password, or one entered in the statement view, is held in memory for the session only and never saved.
- Failed imports and restores remove the PDF copies they made. All-transactions Excel export no longer overwrites a same-day export. Category rename uses the same validation as adding a category (case-insensitive duplicates, length, single line).
- Workspace validation is indexed (linear time) and date validation reuses a formatter. The activity log keeps the latest 5,000 records and each transaction keeps its latest 20 corrections.
- 11 new synthetic regression tests in `StatementCoreTests.swift`.

## Version 0.6: one folder per account (not yet built or tested on a Mac)

- The statement list groups each folder (Bank statements / Credit card statements) into a collapsible sub-folder per account, with a statement count. Selecting or importing a statement opens its account's folder.
- **All transactions to Excel** writes `<destination>/<Bank statements|Credit card statements>/<account>/all-transactions-<date>.xlsx`, one workbook per account; the worksheet is named after the account. Folder names replace `/ : \\`, drop leading dots, and get a ` (2)` suffix when two accounts of the same kind would share a name (case-insensitively).
- One new synthetic test in `SpreadsheetTests.swift`. Run `./scripts/test.sh` and the Release build on the Mac before installing.


## Version 0.7: review fixes (not yet built or tested on a Mac)

- Excel exports drop characters that XML forbids (for example U+0000 or a form feed from PDF text). One such character previously made Excel refuse to open the whole workbook.
- The import sheet no longer pre-fills the period end with today's date. When the PDF's statement date is not detected, the table waits until the period end is entered, because undated rows ("15 DEC") take their year from it.
- PDFs of rolled-back or replaced statements are still kept for Undo during a session, and are now deleted the next time the app opens instead of remaining in Application Support indefinitely. Only the app's own `<UUID>.pdf` copies that no statement references are removed.
- Two new synthetic tests (`SpreadsheetTests.swift`, `StatementCoreTests.swift`). Run `./scripts/test.sh`, the Release build, and `--self-check` on the Mac before installing.

## Version 0.8: remove statements, one folder per card (not yet built or tested on a Mac)

- Restored `App/ContentView.swift` to its last buildable state (`eb9affc`). The later merge into `main` had interleaved two versions of the statement browser (`StatementsView` was missing), so `main` did not compile.
- **Remove Statement…** is now a visible button in the statement header, a right-click item on every statement in the list, an item in the statement's ⋯ menu, and **File → Remove Statement…**. The confirmation names the file and states how many transactions (and reviewed rows) and invoice payment allocations will be removed, and whether the statement was reconciled. Undo restores it during the session.
- Card statements that list several cards (HSBC business cards print a `5592 4033 3870 1617 NAME` heading per card) now record each row's card as its last four digits only. Under **Credit card statements → account**, each card number has its own folder (`Card •••• 1617`); opening a statement from a card folder shows that card's rows, and a Card picker switches between all cards, each card, and account-level rows (repayments, finance charges). Reconciliation always uses every row of the statement.
- **All transactions to Excel** additionally writes `Credit card statements/<account>/Card 1617/all-transactions-<date>.xlsx` for each card. Workbooks and the reviewed CSV get a **Card** column only when card numbers are present, so bank exports keep their layout.
- Parser version `0.5-card-numbers`. Card statements imported earlier have no card numbers: open each one and choose **Retry with OCR…**, or re-import it with replacement, to file its rows by card. Re-extraction replaces corrections, so do it before reviewing.
- One new synthetic test in `HSBCCardTests.swift`.
