# Accounting Boundary

Defines the interface between Sure and the new accounting engine. The goal is
that the rest of Sure never needs to know *how* the ledger stores value —
postings, entries, journals — and that the ledger is independently testable.

This mirrors the standalone spike API in `spikes/double_entry/lib/double_entry/ledger.rb`
(`post_transaction`, `transfer`, `reverse_transaction`, `balance_of`, `balance_at`,
`reconcile`, `observe_bank_balance`) and adapts it to Sure's Rails models.

---

## Namespace

```text
app/models/accounting/
  ledger.rb             # Accounting::Ledger          — the gate
  account.rb            # Accounting::Account          — chart node / type helper
  journal_entry.rb      # Accounting::JournalEntry     — balanced header (AR)
  posting.rb            # Accounting::Posting          — one signed leg (AR)
  account_type.rb       # Accounting::AccountType      — assets/liabilities/equity/income/expenses
  reconciliation.rb     # Accounting::Reconciliation   — value object
  money.rb              # Accounting::Money            — exact monetary value
  errors.rb             # domain errors
```

Layering rule: **only `Accounting::Ledger` may mutate the ledger.** No controller,
job, model, or `Balance::*` class writes `postings`/`journals` directly. Reads by
consumers go through facades (`Account#balance_money`, `Entry#amount_money`,
`Balance`), never through `Accounting::Ledger` directly, except report builders.

---

## Domain Objects

### `Accounting::Money`

Exact monetary value. Two acceptable representations:

- **Preferred (spike):** integer minor units + `Currency` exponent
  (`spikes/double_entry/lib/double_entry/money.rb`). No floating point.
- **Pragmatic (Sure-compatible):** `BigDecimal` with enforced max scale, since
  `lib/money.rb:31` and DB columns are `decimal(19,4)`.

Either way the rule stands: **no `Float` in stored amounts**. `Accounting::Money`
must refuse to combine different currencies (`CurrencyMismatchError`) and reject
input with excess precision (`ExcessPrecisionError`).

### `Accounting::AccountType`

```text
assets      normal balance: debit  (positive)
expenses    normal balance: debit  (positive)
liabilities normal balance: credit (negative)
equity      normal balance: credit (negative)
income      normal balance: credit (negative)
```

Derived from Sure's existing `Account`:
`classification == "asset" | "liability"` (`app/models/account.rb:42`) plus
`accountable_type`. Categories map to `income`/`expenses`.

### `Accounting::Account` (chart node)

Wraps a persisted `Account` record. Attributes: `id`, `name`, `type`, `currency`,
`opening_balance`. In Sure, `name` is hierarchical only by convention (e.g.
`Assets:Bank:Checking`); the persisted `Account#name` stays as-is for the UI.

### `Accounting::Posting`

One signed leg. Maps to an `Entry` row (see mapping doc):

```text
id, journal_id, account_id, amount (signed), currency
```

Effect on balance = the signed amount itself. `balance == sum(postings)`.

### `Accounting::JournalEntry`

A balanced header grouping ≥2 postings:

```text
id, family_id, date, description, currency,
source, external_id, kind, metadata, postings[]
```

Invariant enforced in construction/SQL: `sum(postings) == 0`.

---

## Commands (mutation)

All commands are atomic and idempotent by `(source, external_id)` where supplied.
Every command either succeeds with a journal or raises a domain error; partial
postings are never persisted (spike test "invalid transaction atomic").

### `ledger.post(...)`

```ruby
ledger.post(
  date:,
  description:,
  postings: [ { account:, amount: }, { account:, amount: } ],
  source: nil,
  external_id: nil,
  metadata: {},
  kind: nil
) # => Accounting::JournalEntry
```

- Builds and validates all legs before persisting.
- If `source`+`external_id` already exists → returns the existing journal
  (idempotent).
- Raises `UnbalancedTransactionError` if `sum != 0`,
  `EmptyTransactionError` if `< 2` legs, `CurrencyMismatchError` on mixed
  currencies (single-currency default).

### `ledger.transfer(from:, to:, amount:, date:, description:)`

Convenience producing an ordinary balanced journal. **Not a primitive.**

```text
from -amount
to   +amount
```

Cross-currency transfers: raise unless an explicit FX policy is provided; then
post a third FX gain/loss leg so the journal still sums to zero in each currency
context (see Invariants).

### `ledger.reverse(journal_id)`

Appends the opposite journal; never edits the original. `reversal_of` is stored.

### `ledger.open_account(account, opening_balance:, opened_on:)`

Creates the account (if needed) and, when the opening balance is non-zero, posts:

```text
account                      +opening_balance
Equity:Opening-Balances      -opening_balance
```

The opening balance is therefore a real, auditable posting rather than a hidden
anchor (replaces `app/models/account/opening_balance_manager.rb:69`).

### `ledger.observe_balance(account, balance:, observed_at:, source:, kind:)`

Records a `BalanceObservation` fact. **Never mutates the ledger.**

### `ledger.reconcile(account, observed_balance:)`

Returns an `Accounting::Reconciliation` value object. Never writes.

### `ledger.adjust(account, amount:, reason:, date:)`

The *only* sanctioned way to make the books match reality: posts an explicit
balancing journal (e.g. `Expenses:Bank-Adjustment` against `Assets:...`). This
replaces the silent anchor mutation in
`app/models/account/current_balance_manager.rb:106`.

---

## Queries (read)

```ruby
ledger.balance(account)                 # => Accounting::Money (current)
ledger.balance_at(account, date)        # => Accounting::Money (as of date)
ledger.opening_balance(account)         # => Accounting::Money
ledger.transactions(account)            # => [Accounting::JournalEntry]
ledger.postings(account)                # => [Accounting::Posting]
ledger.accounts_of_type(type)           # => [Accounting::Account]
ledger.reconcile(account, observed:)    # => Accounting::Reconciliation
ledger.accounting_equation             # assets/liabilities/equity/income/expenses
ledger.net_worth                        # assets + liabilities (signed convention)
```

Read-only, side-effect free, and usable in tests without database writes
(in-memory `Ledger` implements the same interface as the AR-backed one — the
spike's `Ledger` is the reference implementation).

---

## Inputs / Outputs

| Direction | Type | Notes |
|---|---|---|
| In | `Accounting::Money`, `Date`, `Account`/id, `Hash` postings | Coerced and validated at the boundary |
| In | `source` + `external_id` | Idempotency key |
| Out | `Accounting::JournalEntry`, `Accounting::Posting` | Immutable once posted |
| Out | `Accounting::Reconciliation` | Value object |
| Out | `Accounting::Money` | Exact, currency-aware |
| Out | Domain exceptions | See below |

---

## Invariants

```text
I1  sum(postings of every journal) == 0
I2  sum(all postings in the ledger) == 0            (holds when opening uses equity)
I3  account.balance == opening_balance + sum(other postings)
I4  external bank balance is an observation and never mutates the ledger
I5  reconciliation never writes to the ledger
I6  journals and postings are append-only (corrections are new journals)
I7  amounts are exact (no floating point)
I8  a journal uses one currency unless an explicit FX policy supplies
    offsetting legs so each currency context sums to zero
```

Invariants I1–I5 are asserted by the existing spike tests
(`spikes/double_entry/test/double_entry_test.rb`). I6–I8 extend them for Sure's
FX and provider realities.

---

## Error Handling

```ruby
module Accounting
  class Error < StandardError; end
  class UnbalancedTransactionError < Error; end
  class EmptyTransactionError < Error; end
  class CurrencyMismatchError < Error; end
  class ExcessPrecisionError < Error; end
  class UnknownAccountError < Error; end
  class DuplicateAccountError < Error; end
  class ConversionError < Error; end
end
```

- Write commands wrap persistence in a DB transaction; a raised error leaves no
  partial postings (spike test "invalid transaction atomic").
- Provider ingestion (`Account::ProviderImportAdapter`) maps
  `DuplicateAccountError`/idempotency lookups to a no-op re-import rather than an
  error, preserving current re-sync behaviour
  (`app/models/account/provider_import_adapter.rb:54`).
- `Accounting::ConversionError` mirrors `Money::ConversionError`
  (`lib/money.rb:5`) so FX callers see consistent errors.
- Domain errors are rescued at the controller/job boundary and surfaced as the
  existing form errors / `DebugLogEntry.capture(...)` where support-relevant.

---

## Sure-facing facade (what consumers may call)

| Consumer need | Allowed call |
|---|---|
| Account balance for UI/API | `account.balance_money` (cache, unchanged) |
| Historical balances | `Balance` rows (cache, unchanged) |
| Net worth / balance sheet | `BalanceSheet` (unchanged) |
| Income/expense reports | `IncomeStatement` (unchanged) |
| Create/edit a transaction | `Accounting::Ledger.post(...)` via controller/import |
| Transfer | `Accounting::Ledger.transfer(...)` |
| Reconcile a bank statement | `Accounting::Ledger.observe_balance` + `.reconcile` |
| Correct a discrepancy | `Accounting::Ledger.adjust(...)` |

Consumers must not: write `postings` directly, read `flows_factor`, read anchor
valuation kinds, or construct unbalanced journals.

---

## Testability

The in-memory `Accounting::Ledger` from `spikes/double_entry/` implements the same
interface, so the boundary can be exercised with zero database and zero Rails. The
AR-backed implementation must pass the same property tests:

```text
- every generated transaction balances
- global sum stays zero
- ordering does not affect balances
- reconciliation does not change ledger state
- reversal leaves the original untouched
- duplicate (source, external_id) is idempotent
```

See `spikes/double_entry/test/double_entry_test.rb` (24 tests) for the reference
suite; port it to run against `Accounting::Ledger` in a Minitest model test.
