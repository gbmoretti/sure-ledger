require "date"

module Accounting
  # The in-memory reference ledger: owns accounts and an append-only journal of
  # journal entries. Balances are always derived from postings; there is no
  # authoritative mutable "current balance" anywhere.
  #
  # This is the executable specification for the AR-backed ledger introduced in
  # Phase 2 (see spikes/spike_2/ACCOUNTING_BOUNDARY.md).
  class Ledger
    OPENING_EQUITY_ACCOUNT = "Equity:Opening-Balances"
    DEFAULT_CURRENCY = "USD"

    attr_reader :observations

    def initialize
      @accounts = {}
      @accounts_by_name = {}
      @transactions = []
      @postings = []
      @observations = []
      @next_account_id = 1
      @next_transaction_id = 1
      @next_posting_id = 1
      @external_index = {}
    end

    def transactions
      @transactions.dup
    end

    def postings
      @postings.dup
    end

    # Creates an account. A non-zero opening balance is immediately
    # materialized as an ordinary balanced opening journal entry against
    # Equity:Opening-Balances, so the opening balance is auditable and the
    # global journal still sums to zero.
    def create_account(name:, type:, currency:, opening_balance: nil, opened_on: nil)
      currency = currency.is_a?(::Money::Currency) ? currency : ::Money::Currency.new(currency)

      if @accounts_by_name.key?(name.to_s)
        raise Errors::DuplicateAccountError, "account already exists: #{name}"
      end

      account = Account.new(
        id: @next_account_id,
        name: name,
        type: type,
        currency: currency,
        opening_balance: opening_balance || Money.zero(currency)
      )

      @next_account_id += 1
      @accounts[account.id] = account
      @accounts_by_name[account.name] = account

      unless account.opening_balance.zero?
        equity = opening_balances_account(currency)
        post_transaction(
          date: opened_on || Date.today,
          description: "Opening balance: #{account.name}",
          postings: [
            { account: account, amount: account.opening_balance },
            { account: equity, amount: -account.opening_balance }
          ],
          opening: true,
          source: "opening",
          external_id: "opening:#{account.id}"
        )
      end

      account
    end
    alias open_account create_account

    def find_account(name)
      @accounts_by_name[name.to_s] || raise(Errors::UnknownAccountError, "unknown account: #{name.inspect}")
    end

    def find_transaction(id)
      @transactions.find { |transaction| transaction.id == id.to_i } ||
        raise(Errors::UnknownTransactionError, "unknown transaction: #{id.inspect}")
    end

    def find_by_external_id(source, external_id)
      @external_index[external_key(source, external_id)]
    end

    # Posts a balanced journal entry atomically: everything is validated on
    # temporary objects before any ledger collection is mutated, so a rejected
    # entry leaves the ledger exactly as it was.
    def post_transaction(date:, description:, postings:, source: nil, external_id: nil,
                         metadata: {}, reversal_of: nil, opening: false)
      date = date.is_a?(Date) ? date : Date.parse(date.to_s)

      if source && external_id
        existing = find_by_external_id(source, external_id)
        return existing if existing
      end

      transaction_id = @next_transaction_id
      first_posting_id = @next_posting_id

      built = postings.each_with_index.map do |raw, index|
        build_posting(raw, transaction_id, first_posting_id + index)
      end

      transaction = JournalEntry.new(
        id: transaction_id,
        date: date,
        description: description,
        postings: built,
        source: source,
        external_id: external_id,
        metadata: metadata,
        reversal_of: reversal_of,
        opening: opening
      )

      @next_transaction_id = transaction_id + 1
      @next_posting_id = first_posting_id + built.size
      @postings.concat(built)
      @transactions << transaction
      @external_index[external_key(source, external_id)] = transaction if source && external_id

      transaction
    end

    # A convenience constructor only: it produces an ordinary balanced journal
    # entry. There is no separate Transfer primitive.
    def transfer(from:, to:, amount:, date:, description: "Transfer")
      from_account = coerce_account(from)
      to_account = coerce_account(to)
      amount = coerce_money(amount, from_account.currency)

      unless from_account.currency == to_account.currency
        raise Errors::CurrencyMismatchError, "transfer accounts must share a currency"
      end
      raise ArgumentError, "transfer amount must be positive" unless amount.positive?

      post_transaction(
        date: date,
        description: description,
        postings: [
          { account: from_account, amount: -amount },
          { account: to_account, amount: amount }
        ],
        source: "transfer"
      )
    end

    # Reverses by appending a new, opposite journal entry. The original is never
    # modified.
    def reverse_transaction(id, date: nil)
      original = find_transaction(id)
      reversal_postings = original.postings.map do |posting|
        { account: @accounts.fetch(posting.account_id), amount: -posting.amount }
      end

      post_transaction(
        date: date || original.date,
        description: "Reversal of #{original.description}",
        postings: reversal_postings,
        reversal_of: original.id,
        source: "reversal",
        external_id: "reversal:#{original.id}"
      )
    end

    def balance_of(account)
      account = coerce_account(account)
      postings_for(account).reduce(Money.zero(account.currency)) { |sum, posting| sum + posting.amount }
    end
    alias get_account_balance balance_of
    alias balance balance_of

    # Historical balance: derived from the ledger as of the given date.
    def balance_at(account, date)
      account = coerce_account(account)
      date = date.is_a?(Date) ? date : Date.parse(date.to_s)
      dates = @transactions.each_with_object({}) { |transaction, map| map[transaction.id] = transaction.date }

      postings_for(account)
        .select { |posting| dates[posting.transaction_id] && dates[posting.transaction_id] <= date }
        .reduce(Money.zero(account.currency)) { |sum, posting| sum + posting.amount }
    end

    # The portion of an account balance that came from opening transactions.
    def opening_balance_of(account)
      account = coerce_account(account)
      opening_ids = @transactions.select(&:opening?).map(&:id)

      postings_for(account)
        .select { |posting| opening_ids.include?(posting.transaction_id) }
        .reduce(Money.zero(account.currency)) { |sum, posting| sum + posting.amount }
    end

    def postings_for(account)
      account = coerce_account(account)
      @postings.select { |posting| posting.account_id == account.id }
    end

    def transactions_for(account)
      ids = postings_for(account).map(&:transaction_id).uniq
      @transactions.select { |transaction| ids.include?(transaction.id) }
    end

    def accounts_of_type(type)
      name = AccountType.coerce(type).name
      @accounts.values.select { |account| account.type.name == name }
    end

    # Compares the ledger balance with an external observation. Returns a
    # value object and never writes to the ledger.
    def reconcile(account, external_balance:, observed_at: nil)
      account = coerce_account(account)
      external_balance = coerce_money(external_balance, account.currency)

      Reconciliation.new(
        account_id: account.id,
        ledger_balance: balance_of(account),
        external_balance: external_balance,
        observed_at: observed_at
      )
    end

    def observe_bank_balance(account, balance:, observed_at: nil)
      account = coerce_account(account)
      observation = BankBalanceObservation.new(
        account_id: account.id,
        observed_at: observed_at,
        balance: coerce_money(balance, account.currency)
      )
      @observations << observation
      observation
    end

    def total_balance(type)
      accounts_of_type(type).reduce(Money.zero(default_currency)) { |sum, account| sum + balance_of(account) }
    end

    def accounting_equation
      {
        assets: total_balance(:assets),
        liabilities: total_balance(:liabilities),
        equity: total_balance(:equity),
        income: total_balance(:income),
        expenses: total_balance(:expenses)
      }
    end

    # Under the signed convention liabilities are credit balances (negative
    # when money is owed), so net worth is assets + liabilities.
    def net_worth
      equation = accounting_equation
      equation[:assets] + equation[:liabilities]
    end

    def global_sum
      @postings.reduce(Money.zero(default_currency)) { |sum, posting| sum + posting.amount }
    end
    alias sum_of_postings global_sum

    def balanced?
      global_sum.zero?
    end

    private

      def default_currency
        @accounts.values.first&.currency ||
          @postings.first&.amount&.currency ||
          ::Money::Currency.new(DEFAULT_CURRENCY)
      end

      def build_posting(raw, transaction_id, posting_id)
        account = coerce_account(raw.fetch(:account))
        amount = coerce_money(raw.fetch(:amount), account.currency)

        unless amount.currency == account.currency
          raise Errors::CurrencyMismatchError, "posting currency differs from account #{account.name}"
        end

        Posting.new(id: posting_id, account_id: account.id, amount: amount, transaction_id: transaction_id)
      end

      def coerce_account(value)
        case value
        when Account
          value
        when String, Symbol
          find_account(value)
        else
          if value.respond_to?(:id) && value.respond_to?(:name) && value.respond_to?(:currency)
            value
          else
            raise Errors::UnknownAccountError, "cannot resolve account: #{value.inspect}"
          end
        end
      end

      def coerce_money(value, currency)
        case value
        when Money
          unless value.currency == currency
            raise Errors::CurrencyMismatchError, "expected #{currency.iso_code} but got #{value.currency.iso_code}"
          end
          value
        when String, Integer, Rational, BigDecimal
          Money.parse(value, currency)
        else
          raise ArgumentError, "cannot coerce #{value.inspect} to Money"
        end
      end

      def opening_balances_account(currency)
        @accounts_by_name[OPENING_EQUITY_ACCOUNT] || create_account(
          name: OPENING_EQUITY_ACCOUNT,
          type: :equity,
          currency: currency
        )
      end

      def external_key(source, external_id)
        [ source.to_s, external_id.to_s ]
      end
  end
end
