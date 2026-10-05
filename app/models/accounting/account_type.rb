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

    # Derives the accounting type of a persisted Sure Account. System
    # (ledger-only) accounts carry their type in the hierarchical name; user
    # accounts use Sure's asset/liability classification.
    def self.for_record(record)
      if record.respond_to?(:system?) && record.system?
        type_from_name(record.name)
      else
        new(record.classification == "liability" ? :liabilities : :assets)
      end
    end

    def self.type_from_name(name)
      root = name.to_s.split(":").first&.downcase
      case root
      when "assets" then new(:assets)
      when "liabilities" then new(:liabilities)
      when "equity" then new(:equity)
      when "income" then new(:income)
      when "expenses" then new(:expenses)
      else
        raise Errors::UnknownAccountTypeError, "cannot derive accounting type from #{name.inspect}"
      end
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
