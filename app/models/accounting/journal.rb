module Accounting
  # A journal entry header grouping two or more balanced postings. In this fork
  # the postings are `Entry` rows sharing a `journal_id`; `amount_minor` is the
  # authoritative signed amount (minor units).
  #
  # Phase 1 introduces the model and its associations only. Phase 2 makes the
  # Ledger write through it.
  class Journal < ApplicationRecord
    self.table_name = "journals"

    belongs_to :family
    has_many :postings,
             class_name: "Entry",
             foreign_key: :journal_id,
             inverse_of: :journal

    validates :date, :description, :currency, presence: true

    # The sum of the postings in minor units. Invariant: must be zero.
    def balance_minor
      postings.sum { |posting| posting.amount_minor.to_i }
    end

    def balanced?
      balance_minor.zero?
    end
  end
end
