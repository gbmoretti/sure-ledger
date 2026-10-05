module Accounting
  # A single signed leg of a journal entry. Positive amounts are debits, negative
  # amounts are credits. The effect of a posting on its account balance is the
  # signed amount itself, so `balance == sum(postings)`.
  class Posting
    attr_reader :id, :account_id, :amount, :transaction_id

    def initialize(id:, account_id:, amount:, transaction_id:)
      @id = Integer(id)
      @account_id = Integer(account_id)
      @amount = amount
      @transaction_id = transaction_id
      freeze
    end

    def debit?
      amount.positive?
    end

    def credit?
      amount.negative?
    end

    def to_s
      "#<Posting #{id} account=#{account_id} amount=#{amount}>"
    end
  end
end
