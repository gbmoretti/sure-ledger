# frozen_string_literal: true

# Phase 1 of the double-entry migration (spikes/spike_2/IMPLEMENTATION_PLAN.md).
# Additive only: no existing table, column or row is changed in place, so the
# running application is unaffected until later phases start writing journals.
class CreateAccountingLedgerTables < ActiveRecord::Migration[8.1]
  def change
    create_table :journals, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.date :date, null: false
      t.text :description, null: false
      t.string :currency, null: false
      t.string :source
      t.string :external_id
      t.string :kind, null: false, default: "standard"
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :journals, [ :family_id, :date ]
    add_index :journals, [ :family_id, :source, :external_id ],
              unique: true,
              where: "external_id IS NOT NULL AND source IS NOT NULL",
              name: "index_journals_on_family_source_external_id"

    # Posts the ledger's signed minor-unit amount alongside the existing decimal
    # `amount`. `amount` stays the consumer-facing projection; `amount_minor` is
    # authoritative for the ledger (see the "ledger-only minor units" decision).
    add_column :entries, :journal_id, :uuid
    add_column :entries, :amount_minor, :bigint
    add_column :entries, :posting_role, :string, null: false, default: "primary"

    add_index :entries, :journal_id
    add_index :entries, [ :journal_id, :posting_role ]
    add_foreign_key :entries, :journals, column: :journal_id

    create_table :balance_observations, id: :uuid do |t|
      t.references :account, null: false, foreign_key: true, type: :uuid
      t.decimal :amount, precision: 19, scale: 4, null: false
      t.string :currency, null: false
      t.datetime :observed_at, null: false
      t.string :source, null: false
      t.string :kind, null: false
      t.string :source_id

      t.timestamps
    end

    add_index :balance_observations, [ :account_id, :source, :kind, :observed_at ],
              unique: true, name: "index_balance_observations_on_identity"

    # Marks ledger-only accounts (Equity/Income/Expense/Liability balancing
    # accounts and the uncategorized/suspense accounts). Phase 1 only adds the
    # flag; Phase 4 excludes these from user-facing scopes.
    add_column :accounts, :system, :boolean, null: false, default: false
    add_index :accounts, [ :family_id, :system ]
  end
end
