require "bigdecimal"

module Accounting
  # Exact monetary value stored as an integer number of minor units (e.g. cents).
  # BigDecimal is used only to parse decimal input exactly; it never enters the
  # stored representation and floating point is never used.
  #
  # Currency metadata comes from Sure's Money::Currency (see config/currencies.yml),
  # whose `minor_unit_conversion` gives the number of minor units per major unit
  # (USD 100, JPY 1, KWD 1000).
  class Money
    include Comparable

    attr_reader :minor_units, :currency

    def initialize(minor_units, currency)
      @minor_units = Integer(minor_units)
      @currency = currency.is_a?(::Money::Currency) ? currency : ::Money::Currency.new(currency)
      freeze
    end

    class << self
      def zero(currency)
        new(0, currency)
      end

      # Builds Money from an exact minor-unit integer.
      def from_minor(minor_units, currency)
        new(minor_units, currency)
      end

      # Parses `value`, interpreted in MAJOR units (e.g. "12.34" USD == 1234
      # minor units). Integer/Rational/String/BigDecimal are all accepted.
      def parse(value, currency)
        currency = normalize_currency(currency)

        case value
        when Money
          unless value.currency == currency
            raise Errors::CurrencyMismatchError, "cannot read #{value.currency.iso_code} as #{currency.iso_code}"
          end
          value
        when Integer
          new(value * factor(currency), currency)
        when Rational
          scaled = value * factor(currency)
          unless scaled.denominator == 1
            raise Errors::ExcessPrecisionError, "#{value} has more decimals than #{currency.iso_code}"
          end
          new(scaled.numerator, currency)
        when String, BigDecimal
          from_big_decimal(BigDecimal(value.to_s), currency)
        else
          raise ArgumentError, "cannot parse #{value.inspect} as Money"
        end
      end

      def exponent(currency)
        prove_power_of_ten(normalize_currency(currency).minor_unit_conversion.to_i) - 1
      end

      private

        def normalize_currency(currency)
          currency.is_a?(::Money::Currency) ? currency : ::Money::Currency.new(currency)
        end

        def factor(currency)
          10**exponent(currency)
        end

        def prove_power_of_ten(conversion)
          unless conversion.positive? && conversion.to_s.match?(/\A10*\z/)
            raise Errors::ConversionError, "unsupported minor_unit_conversion: #{conversion}"
          end

          conversion.to_s.length
        end

        def from_big_decimal(decimal, currency)
          scaled = decimal * factor(currency)
          unless scaled.frac.zero?
            raise Errors::ExcessPrecisionError,
                  "#{decimal} has more than #{exponent(currency)} decimal places for #{currency.iso_code}"
          end
          new(scaled.to_i, currency)
        end
    end

    def exponent
      self.class.exponent(currency)
    end

    def +(other)
      assert_compatible(other)
      self.class.new(minor_units + other.minor_units, currency)
    end

    def -(other)
      assert_compatible(other)
      self.class.new(minor_units - other.minor_units, currency)
    end

    def -@
      self.class.new(-minor_units, currency)
    end

    def *(factor)
      self.class.new(minor_units * Integer(factor), currency)
    end

    def abs
      self.class.new(minor_units.abs, currency)
    end

    def zero?
      minor_units.zero?
    end

    def positive?
      minor_units.positive?
    end

    def negative?
      minor_units.negative?
    end

    def <=>(other)
      assert_compatible(other)
      minor_units <=> other.minor_units
    end

    def ==(other)
      other.is_a?(Money) && other.currency == currency && other.minor_units == minor_units
    end
    alias eql? ==

    def hash
      [ minor_units, currency ].hash
    end

    def to_s
      sign = minor_units.negative? ? "-" : ""
      units = minor_units.abs

      if exponent.zero?
        "#{sign}#{currency.iso_code} #{units}"
      else
        scale = 10**exponent
        major = units / scale
        minor = units % scale
        "#{sign}#{currency.iso_code} #{major}.#{minor.to_s.rjust(exponent, '0')}"
      end
    end

    def inspect
      "#<Money #{self}>"
    end

    private

      def assert_compatible(other)
        return if other.is_a?(Money) && other.currency == currency

        raise Errors::CurrencyMismatchError, "cannot combine #{currency.iso_code} with #{other.inspect}"
      end
  end
end
