module Accounting
  module Errors
    class Error < StandardError; end

    class UnknownAccountTypeError < Error; end
    class UnknownAccountError < Error; end
    class DuplicateAccountError < Error; end
    class UnknownTransactionError < Error; end
    class EmptyTransactionError < Error; end
    class UnbalancedTransactionError < Error; end
    class CurrencyMismatchError < Error; end
    class ExcessPrecisionError < Error; end
    class ConversionError < Error; end
  end
end
