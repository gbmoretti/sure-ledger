# UI Compatibility

For every accounting-related screen/feature: frontend files, API endpoint,
backend dependency, current accounting concepts used, expected impact, and
classification.

Classification:
- **UNCHANGED** — only consumes stable facades/API.
- **SMALL_CHANGE** — limited backend/response adjustment, UI essentially same.
- **REQUIRES_REDESIGN** — feature assumes the current accounting model.

Note: Sure has **no separate `frontend/` directory**. Web UI is ERB + Hotwire
(`app/views`, `app/components`, `app/javascript`). `mobile/` is a Flutter client
of the same `/api/v1` contract.

---

## Accounts

| Field | Value |
|---|---|
| Frontend | `app/views/accounts/index.html.erb`, `index/_account_groups.erb`, `index/_manual_accounts.html.erb`, `_account.html.erb`, `show.html.erb`, `show/_header.html.erb`, `show/_activity.html.erb`, `show/_statements.html.erb`, `_form.html.erb`, `_summary_card.html.erb`; components `app/components/UI/account_page.rb`, `UI/account/chart.rb`, `UI/account/balance_reconciliation.rb`, `UI/account/activity_feed.rb` |
| Controllers | `app/controllers/accounts_controller.rb` (+ per-type `depositories_controller`, `investments_controller`, `credit_cards_controller`, `loans_controller`, `cryptos_controller`, …) |
| API | `GET /api/v1/accounts`, `/accounts/:id` → `app/views/api/v1/accounts/_account.json.jbuilder` |
| Backend dep | `Account`, `accountable`, `balances`, `entries`, `Transfer` (activity feed) |
| Concepts used | `account.balance_money`, `cash_balance_money`, `classification`, `accountable_type`, `subtype`; `Balance#*_money`; `Transfer` pair for the feed |
| Impact | `Account#balance_money`/`cash_balance_money` remain caches; API fields unchanged. Activity feed reads `Transfer` for the counterpart — re-derive from journal. |
| **Class** | **UNCHANGED** (SMALL_CHANGE for the activity-feed transfer lookup) |

## Transactions — list / detail / edit / split / categorize

| Field | Value |
|---|---|
| Frontend | `app/views/transactions/{index,show,_list,_transaction,_form,_transfer_match,_transaction_category}.html.erb`, `_split_parent_row.html.erb`, `entries/_split_group.html.erb`, `splits/{new,edit,_category_select}.html.erb`; components under `app/components/UI/entry*` |
| Controllers | `app/controllers/transactions_controller.rb`, `splits_controller.rb`, `transaction_categories_controller.rb`, `transactions/categorizes_controller.rb` |
| API | `GET/POST/PATCH/DELETE /api/v1/transactions` → `app/views/api/v1/transactions/_transaction.json.jbuilder` |
| Backend dep | `Entry`, `Transaction`, `Category`, `Merchant`, `Tag`, `Transfer` |
| Concepts used | `entry.amount_money`, `entry.classification`, `transaction.category/merchant/tags`, `transaction.kind` (booleans `loan_payment?`, `one_time?`), `transfer`, split `parent_entry`/`child_entries` |
| Impact | List/detail/edit unchanged. The API `transfer` block (`_transaction.json.jbuilder:62`) and `transaction.kind` transfer values must be derived from the journal instead of a `Transfer` row. |
| **Class** | **UNCHANGED** (SMALL_CHANGE for the transfer block) |

## Transfers — create / match / show

| Field | Value |
|---|---|
| Frontend | `app/views/transfers/{new,show,_form,_account_links,update.turbo_stream}.html.erb`, `app/views/transfer_matches/{new,_matching_fields}.html.erb` |
| Controllers | `app/controllers/transfers_controller.rb`, `transfer_matches_controller.rb` |
| API | `GET /api/v1/transfers`, `/transfers/:id`, `/rejected_transfers` → `app/views/api/v1/transfers/*`, `rejected_transfers/*` |
| Backend dep | `Transfer`, `Transfer::Creator`, `Family::AutoTransferMatchable`, `Transaction::Transferable` |
| Concepts used | `transfer.inflow_transaction/outflow_transaction`, `from_account/to_account`, `amount_abs`, `transfer_type`, `derived_source_fee_amount` |
| Impact | `Transfer` model/table removed. Screens can stay if the controller/service builds transfer journals and the serializer derives "the other side" from the journal's sibling posting. Fees become separate journals. |
| **Class** | **SMALL_CHANGE** |

## Balances / reconciliation display

| Field | Value |
|---|---|
| Frontend | `app/components/UI/account/balance_reconciliation.rb`, `app/views/valuations/{index,new,show,confirm_create,confirm_update,_valuation,_header,_confirmation_contents}.html.erb`, `app/views/account_statements/{index,show}.html.erb` |
| Controllers | `app/controllers/valuations_controller.rb`, `account_statements_controller.rb` |
| API | `GET /api/v1/balances`, `/balances/:id`; `GET/POST/PATCH /api/v1/valuations` |
| Backend dep | `Balance`, `Valuation` (`opening_anchor`/`current_anchor`/`reconciliation`), `Account::ReconciliationManager`, `AccountStatement` |
| Concepts used | `Balance#start_*`, `cash_*`, `non_cash_*`, `net_market_flows`, `cash_adjustments`, `flows_factor`; `valuation.opening_anchor?`; reconciliation dry-run `new_cash_balance`/`new_balance` |
| Impact | `Balance` fields can be preserved (derived from postings). `flows_factor` exposed in API must be derived. Anchor kinds replaced by observations; the reconciliation screen keeps its workflow but writes an observation + optional adjustment journal. `Valuation` create/update API semantics shift. |
| **Class** | **SMALL_CHANGE** |

## Net worth / balance sheet / reports

| Field | Value |
|---|---|
| Frontend | `app/views/reports/{index,_net_worth,_investment_performance,_investment_flows,_transactions_breakdown,_trends_insights,_summary_dashboard,print}.html.erb`, dashboard `app/views/pages/dashboard/*` |
| Controllers | `app/controllers/reports_controller.rb`, `pages_controller.rb`, `api/v1/balance_sheet_controller.rb`, `api/v1/cash_flows_controller.rb` |
| API | `GET /api/v1/balance_sheet`, `GET /api/v1/cash_flow` |
| Backend dep | `BalanceSheet`, `BalanceSheet::{AccountTotals,NetWorthSeriesBuilder,...}`, `Balance::ChartSeriesBuilder`, `IncomeStatement` |
| Concepts used | `Account#balance` converted by FX (`balance_sheet/account_totals.rb:103`); `balances`-based series (`balance/chart_series_builder.rb:198`); `net_market_flows` |
| Impact | Unchanged if `accounts.balance` cache and `balances` series remain posting-derived. Investments need mark-to-market postings or series diverge. |
| **Class** | **UNCHANGED** |

## Budgets / budget categories

| Field | Value |
|---|---|
| Frontend | `app/views/budgets/*`, `app/views/budget_categories/*` |
| Controllers | `app/controllers/budgets_controller.rb`, `budget_categories_controller.rb` |
| API | `GET /api/v1/budgets`, `/budgets/:id`, `/budget_categories` |
| Backend dep | `Budget`, `BudgetCategory`, `IncomeStatement`, `Account#balance`, `Transaction::BUDGET_EXCLUDED_KINDS` |
| Concepts used | `family.transactions` + `entries` filters, `entries.account_id`, `kind NOT IN BUDGET_EXCLUDED_KINDS`, `Account#balance` for available cash |
| Impact | Unchanged if `entries`/`balances` projection and `BUDGET_EXCLUDED_KINDS` reporting policy are preserved. `kind` transfer semantics must still be emitted. |
| **Class** | **UNCHANGED** |

## Goals

| Field | Value |
|---|---|
| Frontend | `app/views/goals/*`, `goal_pledges/*` |
| Controllers | `app/controllers/goals_controller.rb`, `goal_pledges_controller.rb` |
| Backend dep | `Goal`, `GoalAccount`, `Account#balance`, `Balance#net_market_flows`, `Entry` |
| Concepts used | account balances (stock), market flows, entry pace sums, pledge matching on reconciliation delta |
| Impact | Unchanged if balances remain posting-derived. `GoalPledge::Reconciler` currently hooked to `ReconciliationManager` (`app/models/account/reconciliation_manager.rb:19`) must be re-homed to the observation writer. |
| **Class** | **UNCHANGED** (SMALL_CHANGE for the pledge hook) |

## Imports (CSV / statements / providers)

| Field | Value |
|---|---|
| Frontend | `app/views/imports/*`, `app/views/import/**` |
| Controllers | `app/controllers/imports_controller.rb`, `app/controllers/import/**`, `api/v1/imports_controller.rb`, `import_sessions_controller.rb` |
| Backend dep | `Import`, `Import::Mapping/Row`, `TransactionImport`, `QifImport`, `PdfImport`, `ProviderImportAdapter` |
| Concepts used | builds `Transaction`+`Entry` directly; `import_locked`, `source`/`external_id`, `reconciled_at` |
| Impact | UI unchanged; persistence changes to post balanced journals. Idempotency preserved via `(source, external_id)`. |
| **Class** | **UNCHANGED** (backend adapt) |

## Investments / trades / holdings

| Field | Value |
|---|---|
| Frontend | `app/views/investments/*`, `app/views/holdings/*`, `app/views/trades/*` |
| Controllers | `app/controllers/investments_controller.rb`, `holdings_controller.rb`, `trades_controller.rb` |
| API | `GET/POST/PATCH/DELETE /api/v1/trades`, `GET /api/v1/holdings`, `/securities`, `/security_prices` |
| Backend dep | `Trade`, `Holding`, `Security`, `SecurityPrice`, `Holding::Materializer`, `Account::MarketDataImporter` |
| Concepts used | `Trade#qty/price/fee`, `realized_gain_loss`, holdings values; `net_market_flows` |
| Impact | Trades/holdings UI unchanged. Ledger must add security postings and mark-to-market journals for the books to balance; `InvestmentStatement` reads `net_market_flows` from `balances`. |
| **Class** | **SMALL_CHANGE** (backend ledger postings; UI same) |

## Rules / merchants / categories

| Field | Value |
|---|---|
| Frontend | `app/views/rules/*`, `app/views/rule/**`, `app/views/family_merchants/*`, `app/views/categories/*`, `app/views/category/**` |
| Controllers | `app/controllers/rules_controller.rb`, `family_merchants_controller.rb`, `categories_controller.rb` |
| API | `GET /api/v1/rules`, `/rule_runs`, `/merchants`, `/categories` |
| Backend dep | `Rule`, `Rule::ActionExecutor::*`, `Category`, `Merchant`, `Tag` |
| Concepts used | mutate `category_id`, `merchant_id`, tags, `entry.name`, `entry.excluded`, `transaction.kind`, and `SetAsTransferOrPayment` creates `Transfer` |
| Impact | UI/API unchanged except `SetAsTransferOrPayment` now builds a balanced transfer journal. Under mapping option B, categories remain metadata. |
| **Class** | **UNCHANGED** (SMALL_CHANGE for the transfer action) |

## Dashboard / recurring / search / insights

| Field | Value |
|---|---|
| Frontend | `app/views/pages/dashboard/*`, `app/views/recurring_transactions/*`, `app/views/insights/*`, transaction search UI |
| Controllers | `pages_controller.rb`, `recurring_transactions_controller.rb`, `insights_controller.rb`, `entry_search.rb` |
| API | `GET /api/v1/recurring_transactions`, `/insights`, `/transactions` (search) |
| Backend dep | `Account`, `Entry`, `Balance`, `Transfer`, `RecurringTransaction`, `Insight` |
| Concepts used | activity feed groups entries + balance rows + transfer pair; recurring matches entries; search filters entries/transactions |
| Impact | Unchanged if projection preserved; activity feed transfer lookup re-derived from journal. |
| **Class** | **UNCHANGED** (SMALL_CHANGE for feed transfer lookup) |

## Mobile (Flutter)

| Field | Value |
|---|---|
| Frontend | `mobile/lib/services/*.dart`, `mobile/lib/models/*.dart` |
| Endpoints | `/api/v1/transactions`, `/accounts`, `/categories`, `/tags`, `/merchants`, `/auth`, `/chats`, `/users` (`mobile/lib/services/transactions_service.dart:29`, `auth_service.dart:352`, …) |
| Backend dep | Same `/api/v1` contract |
| Impact | Unchanged if the JSON contract is preserved. Only the transfer `kind`/`transfer_type` normalization may need a client-side synonym. |
| **Class** | **UNCHANGED** (SMALL_CHANGE if transfer enums change) |

---

## Summary counts

| Classification | Features |
|---|---|
| **UNCHANGED** | Accounts (mostly), transactions list/detail/edit/split/categorize, reports/net worth/balance sheet/cash flow, budgets, goals (mostly), imports, dashboard/recurring/search/insights, rules/merchants/categories (mostly), mobile |
| **SMALL_CHANGE** | Transfer create/match/show, valuation/reconciliation screens, account activity-feed transfer lookup, rule transfer action, goal pledge hook, investments backend postings |
| **REQUIRES_REDESIGN** | None of the user-facing money screens. The only conceptual rewrite is the internal "opening/current balance anchor" model, which has no dedicated screen (it surfaces only as the reconciliation workflow). |

## API endpoints by compatibility

| Endpoint | Backend dependency | Class |
|---|---|---|
| `/api/v1/accounts`, `/balances`, `/budgets`, `/budget_categories`, `/categories`, `/merchants`, `/rules`, `/rule_runs`, `/securities`, `/security_prices`, `/tags`, `/holdings`, `/recurring_transactions`, `/insights`, `/imports` | read fanling models | UNCHANGED |
| `/api/v1/transactions` | `transfer` block | SMALL_CHANGE |
| `/api/v1/transfers`, `/rejected_transfers` | `Transfer` primitive | SMALL_CHANGE |
| `/api/v1/valuations` | anchor kinds | SMALL_CHANGE |
| `/api/v1/trades` | ledger postings (backend) | SMALL_CHANGE |
| `/api/v1/cash_flow`, `/balance_sheet` | `IncomeStatement`/`BalanceSheet` | UNCHANGED |
