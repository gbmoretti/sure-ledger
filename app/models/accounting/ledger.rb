require "date"

module Accounting
  # The AR-backed ledger: the only sanctioned gate for mutating the books.
  # Postings are `Entry` rows sharing a `journal_id`; `amount_minor` is the
  # authoritative signed amount in minor units.
  #
  # Phase 2 introduces the write/query interface. Phase 3 starts routing Sure's
  # transaction and import paths through it.
  class Ledger
    attr_reader :family

    def initialize(family)
      @family = family
    end

    # --- commands -----------------------------------------------------------

    # Posts a balanced journal entry. `postings` are hashes of
    # `{ account:, amount_minor: (or amount: Money), role: }`. Idempotent when
    # both `source` and `external_id` are given.
    def post(date:, description:, postings:, source: nil, external_id: nil, kind: "standard", metadata: {})
      if source && external_id && (existing = find_journal(source, external_id))
        return existing
      end

      normalized = postings.map { |posting| normalize_posting(posting) }
      validate!(normalized)

      Journal.transaction do
        journal = family.journals.create!(
          date: date,
          description: description,
          currency: normalized.first[:currency],
          source: source,
          external_id: external_id,
          kind: kind,
          metadata: metadata
        )

        normalized.each do |posting|
          entry_attributes = {
            journal: journal,
            date: date,
            name: posting[:name] || description,
            amount: posting[:amount].to_d,
            amount_minor: posting[:ledger_minor],
            currency: posting[:currency],
            posting_role: posting[:role],
            entryable: posting[:entryable]
          }.merge(posting[:entry_attributes])

          posting[:account].entries.create!(entry_attributes)
        end

        journal
      end
    end

    # Makes an already-persisted, single-sided Transaction Entry the primary
    # posting of a new balanced journal, adding the Uncategorized
    # counter-posting. Idempotent: an entry that already has a journal is
    # returned unchanged. Used by import/provider paths that build the Entry
    # themselves.
    def attach(entry, counter_type: nil)
      return entry if entry.journal_id.present?
      return entry unless entry.entryable_type == "Transaction"

      currency = entry.currency.presence || currency_for(entry.account)
      sure_minor = Money.parse(entry.amount, currency).minor_units
      ledger_minor = SignConvention.to_ledger(sure_minor)
      type = counter_type || (sure_minor.negative? ? :income : :expenses)
      counter = system_account(type == :income ? "Income:Uncategorized" : "Expenses:Uncategorized", currency)

      Journal.transaction do
        journal = family.journals.create!(
          date: entry.date,
          description: entry.name,
          currency: currency,
          source: entry.source.presence,
          external_id: entry.external_id.present? ? "#{entry.account_id}:#{entry.external_id}" : nil,
          kind: entry.entryable&.kind.presence || "standard"
        )

        entry.update!(journal: journal, amount_minor: ledger_minor, posting_role: "primary")

        counter.entries.create!(
          journal: journal,
          date: entry.date,
          name: entry.name,
          amount: Money.from_minor(SignConvention.to_sure(-ledger_minor), currency).to_d,
          amount_minor: -ledger_minor,
          currency: currency,
          posting_role: "counter"
        )
      end

      entry
    end

    # Creates an account's opening balance as an ordinary balanced journal
    # against Equity:Opening-Balances (replaces the opening-anchor Valuation).
    def open_account(account, opening_balance:, opened_on: nil)
      return if opening_balance.zero?

      record = account_record(account)
      equity = system_account("Equity:Opening-Balances", currency_for(record))

      post(
        date: opened_on || Date.current,
        description: "Opening balance: #{record.name}",
        postings: [
          { account: record, amount_minor: opening_balance.minor_units, role: "primary" },
          { account: equity, amount_minor: -opening_balance.minor_units, role: "counter" }
        ],
        source: "opening",
        external_id: "opening:#{record.id}",
        kind: "opening"
      )
    end

    # Convenience only: produces an ordinary balanced journal. There is no
    # Transfer primitive.
    def transfer(from:, to:, amount:, date:, description: "Transfer")
      from_account = account_record(from)
      to_account = account_record(to)

      raise ArgumentError, "transfer amount must be positive" unless amount.positive?

      post(
        date: date,
        description: description,
        postings: [
          { account: from_account, amount_minor: -amount.minor_units, role: "primary" },
          { account: to_account, amount_minor: amount.minor_units, role: "counter" }
        ],
        source: "transfer",
        kind: "transfer"
      )
    end

    # Appends the opposite journal; the original is never modified.
    def reverse(journal)
      journal = family.journals.find(journal) unless journal.is_a?(Journal)

      post(
        date: journal.date,
        description: "Reversal of #{journal.description}",
        postings: journal.postings.map { |posting|
          { account: posting.account, amount_minor: -posting.amount_minor.to_i, role: posting.posting_role }
        },
        source: "reversal",
        external_id: "reversal:#{journal.id}",
        kind: "reversal"
      )
    end

    # Converts an existing single-sided transaction into one leg of a balanced
    # transfer journal: ensures a journal exists, replaces its Uncategorized
    # counter-posting with a posting on the target account, and returns the new
    # counterpart Entry.
    def convert_to_transfer(source_entry, target_account, counterpart_attributes: {})
      attach(source_entry) unless source_entry.journal_id.present?

      journal = source_entry.journal
      source_minor = source_entry.amount_minor.to_i
      currency = journal.currency

      journal.postings.where(posting_role: "counter").find_each(&:destroy!)

      target_account.entries.create!(
        journal: journal,
        date: source_entry.date,
        name: counterpart_attributes[:name] || "Transfer",
        amount: Money.from_minor(SignConvention.to_sure(-source_minor), currency).to_d,
        amount_minor: -source_minor,
        currency: currency,
        posting_role: "counter",
        entryable: Transaction.new(counterpart_attributes.except(:name))
      )
    end

    # Merges two already-persisted single-sided transaction entries (the two
    # legs of a same-currency transfer) into one balanced journal, discarding
    # their Uncategorized counter-postings. Returns the shared journal.
    def merge_as_transfer(first_entry, second_entry)
      first_entry = attach(first_entry)
      second_entry = attach(second_entry)

      first_journal = first_entry.journal
      second_journal = second_entry.journal

      Journal.transaction do
        (first_journal.postings.to_a + second_journal.postings.to_a).each do |posting|
          posting.destroy! if posting.posting_role == "counter"
        end

        second_entry.update!(journal: first_journal)

        second_journal.destroy! if second_journal.postings.reload.empty?
      end

      first_journal
    end

    # The only sanctioned way to make the books match reality.
    def adjust(account, amount:, reason:, date: Date.current)      record = account_record(account)
                                                                   counter = system_account("Expenses:Bank-Adjustment", currency_for(record))

                                                                   post(
                                                                     date: date,
                                                                     description: reason,
                                                                     postings: [
                                                                       { account: record, amount_minor: amount.minor_units, role: "primary" },
                                                                       { account: counter, amount_minor: -amount.minor_units, role: "counter" }
                                                                     ],
                                                                     kind: "adjustment"
                                                                   )
    end

    # --- observations and reconciliation -----------------------------------

    # Records an external bank balance as a fact. Never mutates the ledger.
    def observe_balance(account, balance:, observed_at:, source:, kind:, source_id: nil)
      record = account_record(account)

      BalanceObservation.create!(
        account: record,
        amount: balance.to_d,
        currency: balance.currency.iso_code,
        observed_at: observed_at,
        source: source,
        kind: kind,
        source_id: source_id
      )
    end

    # Compares the ledger balance with an external observation. Never writes.
    def reconcile(account, observed_balance:, observed_at: nil)
      record = account_record(account)

      Reconciliation.new(
        account_id: record.id,
        ledger_balance: balance(record),
        external_balance: observed_balance,
        observed_at: observed_at
      )
    end

    # --- queries ------------------------------------------------------------

    # Ledger (debit-positive) balance of an account, in minor units.
    def balance(account, at: nil)
      record = account_record(account)
      scope = Entry.where(account_id: record.id, journal_id: Journal.select(:id))
      scope = scope.where("entries.date <= ?", at) if at
      Money.from_minor(scope.sum(:amount_minor).to_i, currency_for(record))
    end

    def balance_at(account, date)
      balance(account, at: date)
    end

    def opening_balance(account)
      record = account_record(account)
      scope = Entry.where(account_id: record.id, journal_id: Journal.where(kind: "opening").select(:id))
      Money.from_minor(scope.sum(:amount_minor).to_i, currency_for(record))
    end

    def postings(account)
      record = account_record(account)
      Entry.where(account_id: record.id).where.not(journal_id: nil)
    end

    def transactions(account)
      record = account_record(account)
      family.journals.where(id: postings(record).select(:journal_id))
    end

    def journals
      family.journals
    end

    def balance_observations(account)
      account_record(account).balance_observations
    end

    def global_sum
      minor = Entry.where(journal_id: Journal.select(:id)).sum(:amount_minor)
      Money.from_minor(minor.to_i, family.currency)
    end

    def balanced?
      global_sum.zero?
    end

    private

      def normalize_posting(posting)
        account = account_record(posting.fetch(:account))
        ledger_minor = minor_of(posting)
        currency = posting[:currency] || currency_for(account)
        sure_money = Money.from_minor(SignConvention.to_sure(ledger_minor), currency)

        {
          account: account,
          ledger_minor: ledger_minor,
          currency: currency,
          amount: sure_money,
          role: (posting[:role] || "primary").to_s,
          name: posting[:name],
          entryable: posting[:entryable],
          entry_attributes: posting[:entry_attributes] || {}
        }
        end

      def minor_of(posting)
        value = posting[:amount_minor] || posting[:amount]

        case value
        when Money then value.minor_units
        when Integer then value
        else raise ArgumentError, "posting amount must be Money or integer minor units"
        end
      end

      def validate!(normalized)
        raise Errors::EmptyTransactionError, "a journal entry requires at least two postings" if normalized.size < 2

        unless normalized.sum { |posting| posting[:ledger_minor] }.zero?
          raise Errors::UnbalancedTransactionError, "postings must sum to zero"
        end

        if normalized.map { |posting| posting[:currency] }.uniq.size > 1
          raise Errors::CurrencyMismatchError, "a single journal entry must use one currency"
        end
      end

      def system_account(name, currency)
        family.accounts.find_by(name: name, system: true, currency: currency) || family.accounts.create!(
          name: name,
          accountable: LedgerAccount.new,
          balance: 0,
          cash_balance: 0,
          currency: currency,
          system: true
        )
      end
      public :system_account

      def account_record(value)
        case value
        when ::Account then value
        when String then family.accounts.find(value)
        else
          raise Errors::UnknownAccountError, "cannot resolve account: #{value.inspect}" unless value.respond_to?(:entries)
          value
        end
      end

      def currency_for(record)
        record.currency.presence || family.currency
      end

      def find_journal(source, external_id)
        family.journals.find_by(source: source, external_id: external_id)
      end
  end
end
