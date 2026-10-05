module Accounting
  # A balanced journal entry: a header plus two or more balanced postings. The
  # invariant `sum(postings) == 0` is enforced in the constructor, so an
  # unbalanced entry can never be constructed, let alone appended.
  class JournalEntry
    attr_reader :id, :date, :description, :postings, :source, :external_id,
                :metadata, :reversal_of

    def initialize(id:, date:, description:, postings:, source: nil, external_id: nil,
                   metadata: {}, reversal_of: nil, opening: false)
      @id = id
      @date = date
      @description = description.to_s
      @postings = postings.freeze
      @source = source
      @external_id = external_id
      @metadata = metadata.freeze
      @reversal_of = reversal_of
      @opening = opening

      validate!
      freeze
    end

    def opening?
      @opening
    end

    def currency
      postings.first&.amount&.currency
    end

    def total
      postings.reduce(Money.zero(currency)) { |sum, posting| sum + posting.amount }
    end

    def balanced?
      total.zero?
    end

    def amount_for(account)
      postings
        .select { |posting| posting.account_id == account.id }
        .reduce(Money.zero(currency)) { |sum, posting| sum + posting.amount }
    end

    def to_s
      "#<JournalEntry #{id} #{date} #{description}>"
    end

    private

      def validate!
        raise Errors::EmptyTransactionError, "a journal entry requires at least two postings" if postings.size < 2

        currencies = postings.map { |posting| posting.amount.currency }.uniq
        if currencies.size > 1
          raise Errors::CurrencyMismatchError, "a single journal entry must use one currency"
        end

        return if balanced?

        raise Errors::UnbalancedTransactionError, "postings must sum to zero but summed to #{total}"
      end
  end
end
