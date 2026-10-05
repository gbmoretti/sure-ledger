require_relative "../../../config/environment"
require "minitest/autorun"

class Accounting::SignConventionTest < Minitest::Test
  def test_sure_to_ledger_is_negation
    assert_equal(-100, Accounting::SignConvention.to_ledger(100))
    assert_equal 100, Accounting::SignConvention.to_ledger(-100)
    assert_equal 0, Accounting::SignConvention.to_ledger(0)
  end

  def test_ledger_to_sure_is_negation
    assert_equal 100, Accounting::SignConvention.to_sure(-100)
    assert_equal(-100, Accounting::SignConvention.to_sure(100))
  end

  def test_round_trip
    [ -1234, 0, 5678 ].each do |amount|
      assert_equal amount, Accounting::SignConvention.to_sure(Accounting::SignConvention.to_ledger(amount))
    end
  end
end
