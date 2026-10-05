module Accounting
  # Posts a user-facing transaction as a balanced journal: the real account's
  # posting plus a counter-posting to the synthetic Uncategorized income/expense
  # account. The business metadata (category, merchant, tags, kind, notes)
  # stays on the primary Entry's Transaction, so the UI and reports are
  # unchanged; the counter-posting is ledger-only.
  #
  # Returns the primary Entry (the row the UI already knows and shows).
  class PostTransaction
    def initialize(family:, account:, attributes:)
      @family = family
      @account = account
      @attributes = attributes.to_h.deep_symbolize_keys
    end

    def call
      currency = @attributes[:currency].presence || @account.currency.presence || @family.currency
      sure_minor = Money.parse(@attributes.fetch(:amount), currency).minor_units
      ledger_minor = SignConvention.to_ledger(sure_minor)
      counter = counter_account(sure_minor.negative? ? :income : :expenses, currency)
      entryable = build_entryable

      journal = Ledger.new(@family).post(
        date: @attributes[:date],
        description: @attributes[:name],
        postings: [
          {
            account: @account,
            amount_minor: ledger_minor,
            role: "primary",
            currency: currency,
            entryable: entryable,
            entry_attributes: primary_entry_attributes
          },
          { account: counter, amount_minor: -ledger_minor, role: "counter", currency: currency }
        ],
        source: @attributes[:source] || (@attributes[:idempotency_key] ? "manual" : nil),
        external_id: @attributes[:external_id] || @attributes[:idempotency_key],
        kind: entryable.kind.presence || "standard"
      )

      journal.postings.find_by(posting_role: "primary")
    end

    private

      def build_entryable
        Transaction.new((@attributes[:entryable_attributes] || {}).except(:id))
      end

      def primary_entry_attributes
        {
          name: @attributes[:name],
          notes: @attributes[:notes],
          excluded: @attributes[:excluded].present?,
          idempotency_key: @attributes[:idempotency_key],
          external_id: @attributes[:external_id],
          source: @attributes[:source]
        }.compact
      end

      def counter_account(type, currency)
        name = type == :income ? "Income:Uncategorized" : "Expenses:Uncategorized"

        @family.accounts.find_by(name: name, system: true, currency: currency) || @family.accounts.create!(
          name: name,
          accountable: LedgerAccount.new,
          balance: 0,
          cash_balance: 0,
          currency: currency,
          system: true
        )
      end
  end
end
