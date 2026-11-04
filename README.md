# Statement Manager for macOS

A native workspace with local storage and optional DeepSeek assistance for HKD bank/card statements and client invoice matching. Built with SwiftUI, PDFKit, Vision and SwiftData. No app server, bank credentials, telemetry, or cloud sync. Optional, explicitly requested AI suggestions use the DeepSeek API.

## Build and run

Requirements: Apple silicon Mac, macOS 14+, Xcode with the macOS SDK. This release targets arm64. Package downloads require internet during development; statement processing works locally without it; optional DeepSeek suggestions require internet.

1. Open `StatementManager.xcodeproj` in Xcode.
2. Select **StatementManager → My Mac**, then Run. Signing uses a local ad-hoc identity; no developer account is needed on this Mac.
3. Or run `./scripts/build.sh` to produce `~/Library/Developer/StatementManager/Release/Statement Manager.app` (outside cloud-synchronized folders, which can add metadata that invalidates signatures).
4. Copy that app to your Applications folder and open it. For distribution to other Macs, use your Developer ID to sign and notarize it; this local build is not notarized.
5. Set your business name and add the relevant HSBC / Bank of China (Hong Kong) bank and card accounts. Account nicknames are sufficient; full account numbers are unnecessary.

`Package.resolved` pins the dependencies. CoreXLSX reads spreadsheets; ZIPFoundation reads workbook date metadata. The small Python project generator is a development convenience, not an installed-app runtime dependency.

## First statement cycle

1. Import one or several PDFs with **File → Import Statements** (⌘I), the toolbar, or drag-and-drop.
2. The PDF is read automatically. Confirm the suggested account and detected statement date (or choose an account if several match). **Read PDF** retries extraction. A password stays in memory only and is cleared after extraction; the preserved original remains protected.
3. Review the transaction table and warnings, then choose **Import transactions**. A zero-row result is explained explicitly and can only be saved by choosing manual entry. Exact duplicate files cannot create another statement. OCR replacement is an explicit operation, and existing invoice allocations must be reversed first.
4. Select a transaction to highlight its source. Double-click or choose **Review selected transaction** to edit it. Bank inflows are positive. Card charges are positive; repayments and refunds reduce the amount owed.
5. Add missing rows manually, remove false extractions, and resolve possible duplicates. Unknown formats are preserved for manual review rather than guessed.
6. Verify opening/closing balances, then mark reconciled only when every row is reviewed and the difference is zero.
7. Add specific merchant rules. Preview matches before saving/applying. A category suggestion never marks a transaction reviewed. Equal-priority conflicting results remain unclassified; manual corrections take precedence.
8. Export reviewed transactions as UTF-8 CSV, including source references and the account-specific amount convention.

**Important:** HSBC and BOC bank/card profile scaffolds are deliberately marked **unvalidated**. They currently recognize conservative, positioned-column or explicit DR/CR rows. They are not certified against your actual statements. Provide two periods per bank/card layout before production acceptance. Balance equality alone does not prove that every row is correct. Confirm counts, dates, amounts, signs, and references against manually checked originals.

## Invoice register and matching

Use **File → Import Invoice Register** (⇧⌘I). Select an Excel worksheet or UTF-8 CSV and map:

| Field | Required | Example |
| --- | --- | --- |
| Invoice number | Yes; text recommended | INV-0001 |
| Client | Yes | Example Client |
| Invoice date | Yes | 2026-01-01 |
| Original total | Yes | 1200.50 |
| Starting outstanding | Yes | 1200.50 |
| Due date | Optional | 2026-02-01 |
| Currency | Optional; defaults to HKD | HKD |

Dates support ISO and day/month/year. XLSX numeric dates support 1900 and 1904 systems, and simple zero-padded numeric identifier formats are preserved. Save formula workbooks in Excel before import so cached values are current. Legacy `.xls` and encrypted spreadsheets must be saved as unencrypted `.xlsx` or CSV. Headers must be the first nonempty row.

The outstanding column is a **baseline**. The app subtracts only payments allocated here. When importing updates, do not substitute a later outstanding amount that already includes those same payments. Updates require explicit review and retain allocation links. Invoice numbers must be unique across the business; conflicting client identities are rejected.

In **Invoices → Match a payment**, choose a reviewed incoming bank transaction and confirm invoice/amount. Partial payments, multiple payments, and splitting one payment across invoices are supported. Excess remains unallocated. Suggestions do not post automatically. Reverse mistaken allocations from invoice details. Client aliases are separated by semicolons.

Reports show reviewed cash movements, net categorized expenses, and invoice balances. Transfers are excluded. These are not double-entry financial statements or tax classifications. Version one supports up to 50,000 transactions, invoices, and allocations each.

## DeepSeek AI settings

Version 0.2 adds **AI Settings…** in the app menu, sidebar, and Workspace Settings.

1. Quit and reopen the updated app.
2. Open **AI Settings…**, paste your DeepSeek API key into the secure field, and choose **Save key**. Do not paste the key into chat or source code.
3. Choose **Test connection** to verify that your saved key can access `deepseek-flash`. This calls the models endpoint and sends no transaction data.
4. Enable **DeepSeek assistance** (off by default).
5. Open a transaction for review and choose **Suggest category**. Review the explanation, choose **Use suggestion**, then verify the transaction and save it. Applying a suggestion resets its reviewed checkbox; it never posts an invoice allocation or changes amounts.

The model is exactly `deepseek-flash`, with the official endpoint `https://api.deepseek.com/chat/completions`. No alternative model is silently substituted. Requests use JSON output and non-thinking mode with a bounded output size. Your DeepSeek API billing applies.

Only the selected transaction description, incoming/outgoing direction, HKD currency, allowed categories and transaction types are submitted. Descriptions may contain client names or references. The app does not submit PDFs, exact amounts, dates, balances, or the invoice register. Import/OCR/rules remain local, and nothing is sent automatically. Disabled AI prevents category requests; the explicit connection-test button can still check credentials.

API keys are saved in the local macOS Keychain, not the workspace, logs, exports, or backups. Keys are not synchronized by this app. **Remove key** deletes the saved credential and switches assistance off. Network failures or invalid responses leave the transaction unchanged; returned categories and types are validated. Redirects are blocked to avoid forwarding credentials to another endpoint. Requests use an ephemeral session without cookies or response caching.

[DeepSeek API reference](https://api-docs.deepseek.com/guides/harness) · [JSON output](https://api-docs.deepseek.com/guides/json_mode/)

## Data protection and recovery

- SwiftData and original PDFs live in the sandbox container under `Library/Application Support/StatementManager`. CloudKit is explicitly disabled.
- The SwiftData record contains a versioned workspace payload. Each save validates and commits the whole workspace atomically, so related payments and balances cannot persist half-updated.
- Enable FileVault and encrypted Time Machine backups. The app database and portable backup are **not separately encrypted**.
- **Create Backup** writes a `.hkledger` folder containing the workspace and originals. Choose an encrypted destination. Restore validates originals by SHA-256 before replacing data and preserves old files for Undo.
- ⌘Z / ⇧⌘Z undo and redo the last 30 actions during the current session. Prior transaction revisions and a local action log are persisted. Statement rollback removes its transactions and allocations but leaves invoices. Latest invoice-batch rollback is refused if it would invalidate allocations.
- Rolled-back originals are retained locally for recovery; there is no automatic secure deletion claim.
- Logs contain no raw financial records. CSV export neutralizes formula-like text while retaining numeric amount columns.
- Keep real samples in `PrivateSamples/`; PDFs, spreadsheets, CSVs, databases, and build outputs are excluded from Git.

## Tests and synthetic demo

Run `./scripts/test.sh`. DeepSeek tests use mocked responses, never real credentials or paid requests. Tests generate synthetic documents at runtime; no real financial samples are committed. The suite covers monetary precision, CSV parsing/export protection, XLSX dates and identifiers, OCR, protected PDFs, conservative profile scaffolds, matching/allocation limits, updates, rollback, reconciliation, and SwiftData/backup round trips.

The installed app is at `~/Applications/Statement Manager.app`. Quit the demo preview before opening it normally.

For UI review, launch the built app with `--demo`. It uses a **separate** `StatementManagerDemo` store containing synthetic data. Launch normally to use the real workspace. The demo is never loaded into a normal workspace.

The packaged app also supports `--self-check`, which runs a synthetic end-to-end check inside the sandbox without opening a window or touching the normal workspace. See [VALIDATION.md](VALIDATION.md) for the completed checks.

Production acceptance remains blocked on real layout samples and a reviewed pilot category dataset (target: at least 95% precision among automatically categorized transactions). No production OCR/category accuracy claim is made from synthetic tests.

## Apple references

- [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
- [PDFKit](https://developer.apple.com/documentation/pdfkit)
- [Vision text recognition](https://developer.apple.com/documentation/vision/recognizing-text-in-images)
- [SwiftData](https://developer.apple.com/documentation/swiftdata)
- [App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)

## Version 0.3: recovering an empty table

Previously imported PDFs with zero rows are retried locally once per launch. The app recovers the table only when the source hash, printed transaction count, and statement balances agree. Existing transactions are never overwritten by this recovery, and recovered rows remain unreviewed. You can Undo the recovery. Unsupported imports show **Extract transactions** instead of a blank list. Use **Show PDF** to expand the transaction table when reviewing many rows.

## Transaction types and references

Bank amounts display an explicit + for credits and − for debits. The statement and transaction tables include separate Type, Reference, and Category columns. Transactions can be filtered by money in/out and sorted by date, type, or category. Credit-card storage retains its amount-owed convention, explained beside the filters.

Description-based suggestions recognize explicit refunds, client payments, cheque deposits, expenses, charges, eCheques, and bank transfers. Sign alone never establishes income or the payer. Missing references stay blank; leading zeros are preserved. Existing reviewed/manual corrections remain untouched. Only confirmed Internal Transfer entries are excluded from income/expense totals; an ordinary Bank Transfer is not presumed internal. Existing unreviewed rows are organized on launch, with Undo available.

## Version 0.4: custom classification items

Use **Add type…** or **Add category…** in the transaction editor (or rule editor) to create a reusable workspace item. Names are trimmed, support Chinese text, and cannot duplicate existing names. Added items are saved immediately; the transaction itself changes only when you press Save. Custom types are descriptive labels; choose the built-in Internal Transfer for confirmed transfers between your own accounts.

The transaction and statement tables now show **Payee / Client** from the editable transaction field. Missing names display a dash. Custom type labels participate in search, type sorting, rules, and CSV exports. Older workspaces remain readable.

## Version 0.4.1: review fixes

Restored the sandbox entitlements and substantive test suite. The Xcode project generator now retains a Test action with the same tests as SwiftPM. Run `./scripts/test.sh` or Xcode Product → Test.

Bank date continuation now survives adjacent-page carried-forward/brought-forward balances. Description extraction respects the actual amount columns, preserving foreign-currency figures and invoice references inside details. Invoice matching removes presentation labels such as “INVOICE ” while preserving leading zeros and meaningful prefixes such as “INV-”. Workspace Settings uses the same duplicate-category validation as transaction review.

Existing imported rows are not reparsed automatically by this update. Use the statement’s re-extraction flow to recover previously omitted rows or truncated descriptions; review the replacement warning because it replaces transaction corrections.

## Version 0.4.2: application icon

The application uses the supplied red circle / white "Statement" design. Approved transparent artwork is stored at App/Resources/AppIcon.png. Rebuild the macOS icon with `swift scripts/make_icon.swift /tmp/StatementManager.iconset`, followed by `iconutil -c icns /tmp/StatementManager.iconset -o App/Resources/AppIcon.icns`. The icon includes 16–1024 pixel representations.
