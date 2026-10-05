module Accounting
  # A chart-of-accounts node. In the Sure fork this wraps a persisted Account
  # record; the standalone reference keeps it in memory.
  class Account
    attr_reader :id, :name, :type, :currency, :opening_balance

    def initialize(id:, name:, type:, currency:, opening_balance: nil)
      @id = id
      @name = name.to_s
      @type = AccountType.coerce(type)
      @currency = currency.is_a?(::Money::Currency) ? currency : ::Money::Currency.new(currency)
      @opening_balance = opening_balance || Money.zero(@currency)

      unless @opening_balance.currency == @currency
        raise Errors::CurrencyMismatchError, "opening balance currency differs from account currency"
      end

      freeze
    end

    # Wraps a persisted Sure Account record.
    def self.from_record(record)
      new(
        id: record.id,
        name: record.name,
        type: AccountType.for_record(record),
        currency: record.currency.presence || record.family.currency
      )
    end

    def asset?
      type.name == :assets
    end

    def liability?
      type.name == :liabilities
    end

    def equity?
      type.name == :equity
    end

    def income?
      type.name == :income
    end

    def expense?
      type.name == :expenses
    end

    def root
      name.split(":").first
    end

    def to_s
      name
    end

    def inspect
      "#<Account #{id} #{name} (#{type})>"
    end
  end
end
