module Accounting
  # The five accounting account types. `normal_balance` documents which side
  # increases the account under the signed, debit-positive convention used by
  # the ledger (assets and expenses are debit-normal; the rest credit-normal).
  class AccountType
    NORMAL_BALANCES = {
      assets: :debit,
      liabilities: :credit,
      equity: :credit,
      income: :credit,
      expenses: :debit
    }.freeze

    attr_reader :name, :normal_balance

    def initialize(name)
      @name = name.to_sym
      @normal_balance = NORMAL_BALANCES.fetch(@name) do
        raise Errors::UnknownAccountTypeError, "unknown account type: #{name.inspect}"
      end
      freeze
    end

    def self.coerce(value)
      value.is_a?(AccountType) ? value : new(value)
    end

    def self.names
      NORMAL_BALANCES.keys
    end

    def debit_normal?
      normal_balance == :debit
    end

    def credit_normal?
      normal_balance == :credit
    end

    def ==(other)
      other.is_a?(AccountType) && other.name == name
    end
    alias eql? ==

    def hash
      name.hash
    end

    def to_s
      name.to_s
    end
  end
end
