# frozen_string_literal: true

# Phase 2: the accountable type used by ledger-only system accounts
# (Equity:Opening-Balances, Expenses:Uncategorized, ...). It is deliberately
# not part of Accountable::TYPES, so it never appears in account-type pickers;
# system accounts are flagged and excluded from user-facing scopes in Phase 4.
class CreateLedgerAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :ledger_accounts, id: :uuid do |t|
      t.jsonb :locked_attributes, null: false, default: {}
      t.string :subtype

      t.timestamps
    end
  end
end
