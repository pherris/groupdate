require "groupdate/version"
require "active_record"

module Groupdate
  extend ActiveSupport::Concern

  # Pattern from kaminari
  # https://github.com/amatsuda/kaminari/blob/master/lib/kaminari/models/active_record_extension.rb
  included do
    # Future subclasses will pick up the model extension
    class << self
      def inherited_with_groupdate(kls) #:nodoc:
        inherited_without_groupdate kls
        kls.send(:include, ClassMethods) if kls.superclass == ActiveRecord::Base
      end
      alias_method_chain :inherited, :groupdate
    end

    # Existing subclasses pick up the model extension as well
    self.descendants.each do |kls|
      kls.send(:include, ClassMethods) if kls.superclass == ActiveRecord::Base
    end
  end

  module ClassMethods
    extend ActiveSupport::Concern

    included do
      # Field list from
      # http://www.postgresql.org/docs/9.1/static/functions-datetime.html
      time_fields = %w(second minute hour day week month year)
      number_fields = %w(day_of_week hour_of_day)
      (time_fields + number_fields).each do |field|
        self.scope :"group_by_#{field}", lambda {|*args|
          column = connection.quote_table_name(args[0])
          time_zone = args[1] || Time.zone || "Etc/UTC"
          if time_zone.is_a?(ActiveSupport::TimeZone) or time_zone = ActiveSupport::TimeZone[time_zone]
            time_zone = time_zone.tzinfo.name
          else
            raise "Unrecognized time zone"
          end
          query =
            case connection.adapter_name
            when "MySQL", "Mysql2"
              case field
              when "day_of_week" # Sunday = 0, Monday = 1, etc
                # use CONCAT for consistent return type (String)
                ["DAYOFWEEK(CONVERT_TZ(#{column}, '+00:00', ?)) - 1", time_zone]
              when "hour_of_day"
                ["EXTRACT(HOUR from CONVERT_TZ(#{column}, '+00:00', ?))", time_zone]
              when "week"
                ["CONVERT_TZ(DATE_FORMAT(CONVERT_TZ(DATE_SUB(#{column}, INTERVAL (DAYOFWEEK(CONVERT_TZ(#{column}, '+00:00', ?)) - 1) DAY), '+00:00', ?), '%Y-%m-%d 00:00:00'), ?, '+00:00')", time_zone, time_zone, time_zone]
              else
                format =
                  case field
                  when "second"
                    "%Y-%m-%d %H:%i:%S"
                  when "minute"
                    "%Y-%m-%d %H:%i:00"
                  when "hour"
                    "%Y-%m-%d %H:00:00"
                  when "day"
                    "%Y-%m-%d 00:00:00"
                  when "month"
                    "%Y-%m-01 00:00:00"
                  else # year
                    "%Y-01-01 00:00:00"
                  end

                ["CONVERT_TZ(DATE_FORMAT(CONVERT_TZ(#{column}, '+00:00', ?), '#{format}'), ?, '+00:00')", time_zone, time_zone]
              end
            when "PostgreSQL"
              case field
              when "day_of_week"
                ["EXTRACT(DOW from #{column}::timestamptz AT TIME ZONE ?)", time_zone]
              when "hour_of_day"
                ["EXTRACT(HOUR from #{column}::timestamptz AT TIME ZONE ?)", time_zone]
              when "week" # start on Sunday, not PostgreSQL default Monday
                ["(DATE_TRUNC('#{field}', (#{column}::timestamptz + INTERVAL '1 day') AT TIME ZONE ?) - INTERVAL '1 day') AT TIME ZONE ?", time_zone, time_zone]
              else
                ["DATE_TRUNC('#{field}', #{column}::timestamptz AT TIME ZONE ?) AT TIME ZONE ?", time_zone, time_zone]
              end
            else
              raise "Connection adapter not supported: #{connection.adapter_name}"
            end

          if args[2] # zeros
            if time_fields.include?(field)
              # TODO ensure range

              # determine start time
              time = args[2].first.in_time_zone(time_zone)
              starts_at =
                case field
                when "second"
                  time.change(min: 0)
                when "day"
                  time.beginning_of_day
                end
            end

            derived_table =
              case connection.adapter_name
              when "PostgreSQL"
                case field
                when "day_of_week", "hour_of_day"
                  max = field == "day_of_week" ? 6 : 23
                  "SELECT generate_series(0, #{max}, 1) AS #{field}"
                else
                  sanitize_sql_array(["SELECT (generate_series(CAST(? AS timestamptz) AT TIME ZONE ?, ?, ?) AT TIME ZONE ?) AS #{field}", starts_at, time_zone, args[2].last, "1 #{field}", time_zone])
                end
              else # MySQL
                case field
                when "day_of_week", "hour_of_day"
                  max = field == "day_of_week" ? 6 : 23
                  (0..max).map{|i| "SELECT #{i} AS #{field}" }.join(" UNION ")
                else
                  series = [starts_at]

                  step =
                    case field
                    when "second"
                      1.second
                    when "day"
                      1.day
                    end

                  while series.last < args[2].last
                    series << series.last + step
                  end

                  sanitize_sql_array([series.map{|i| "SELECT CAST(? AS DATETIME) AS #{field}" }.join(" UNION ")] + series)
                end
              end
            joins("RIGHT OUTER JOIN (#{derived_table}) groupdate_series ON groupdate_series.#{field} = (#{sanitize_sql_array(query)})").group(Groupdate::OrderHack.new("groupdate_series.#{field}", field))
          else
            group(Groupdate::OrderHack.new(sanitize_sql_array(query), field))
          end
        }
      end
    end
  end

  class OrderHack < String
    attr_reader :field

    def initialize(str, field)
      super(str)
      @field = field
    end
  end
end

ActiveRecord::Base.send :include, Groupdate

# hack for **unfixed** rails issue
# https://github.com/rails/rails/issues/7121
module ActiveRecord
  module Calculations

    def column_alias_for_with_hack(*keys)
      if keys.first.is_a?(Groupdate::OrderHack)
        keys.first.field
      else
        column_alias_for_without_hack(*keys)
      end
    end
    alias_method_chain :column_alias_for, :hack

  end
end
