class Rule::ActionExecutor::SetAsTransferOrPayment < Rule::ActionExecutor
  def type
    "select"
  end

  def options
    family.accounts.alphabetically.pluck(:name, :id)
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    target_account = family.accounts.find_by_id(value)
    return 0 unless target_account
    scope = transaction_scope.with_entry

    count_modified_resources(scope) do |txn|
      entry = txn.entry
      unless txn.transfer?
        destination_account = target_account
        outflow_kind = Transfer.kind_for_account(destination_account)

        counterpart_entry = Accounting::Ledger.new(family).convert_to_transfer(
          entry,
          destination_account,
          counterpart_attributes: {
            name: "#{destination_account.liability? ? "Payment" : "Transfer"} #{entry.amount.negative? ? "to #{destination_account.name}" : "from #{entry.account.name}"}",
            kind: "funds_movement"
          }
        )

        # The Transfer join is kept for the transfers UI until Phase 7 derives
        # the counterpart from the journal instead.
        transfer = nil
        Transfer.transaction do
          transfer = Transfer.find_or_initialize_by(
            inflow_transaction: entry.amount.positive? ? counterpart_entry.transaction : entry.transaction,
            outflow_transaction: entry.amount.positive? ? entry.transaction : counterpart_entry.transaction
          )
          transfer.status = "confirmed"
          transfer.save!

          # Use DESTINATION (inflow) account for kind, matching Transfer::Creator logic
          outflow_attrs = { kind: outflow_kind }
          if outflow_kind == "investment_contribution"
            category = destination_account.family.investment_contributions_category
            outflow_attrs[:category] = category if category.present? && transfer.outflow_transaction.category_id.blank?
          end

          transfer.outflow_transaction.update!(outflow_attrs)
          transfer.inflow_transaction.update!(kind: "funds_movement")
        end

        transfer.sync_account_later
      end
    end
  end
end
