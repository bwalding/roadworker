module Roadworker
  class DSL

    class << self
      def define(source, path, lineno = 1)
        self.new(path) do
          eval(source, binding, path, lineno)
        end
      end

      def convert(hosted_zones)
        Converter.convert(hosted_zones)
      end

      def test(dsl, options)
        Tester.test(dsl, options)
      end
    end # of class method

    attr_reader :result

    def initialize(path, &block)
      @path = path
      @result = OpenStruct.new({:hosted_zones => []})
      instance_eval(&block)
    end

    private

    def require(file)
      routefile = (file =~ %r|\A/|) ? file : File.expand_path(File.join(File.dirname(@path), file))

      if File.exist?(routefile)
        instance_eval(File.read(routefile), routefile)
      elsif File.exist?(routefile + '.rb')
        instance_eval(File.read(routefile + '.rb'), routefile + '.rb')
      else
        Kernel.require(file)
      end
    end

    def hosted_zone(name, &block)
      @result.hosted_zones << HostedZone.new(name, [], &block).result
    end

    class HostedZone
      attr_reader :result

      def initialize(name, rrsets = [], &block)
        @name = name

        @result = OpenStruct.new({
          :name => name,
          :vpcs => [],
          :resource_record_sets => rrsets,
          :rrsets => rrsets,
        })

        instance_eval(&block)
      end

      private

      def vpc(vpc_region, vpc_id)
        unless vpc_region
          raise "Invalid VPC Region: #{vpc_region.inspect}"
        end

        unless vpc_id
          raise "Invalid VPC ID: #{vpc_id}"
        end

        vpc_h = Aws::Route53::Types::VPC.new(:vpc_region => vpc_region.to_s, :vpc_id => vpc_id.to_s)

        if @result.vpcs.include?(vpc_h)
          raise "VPC is already defined: #{vpc_h.inspect}"
        end

        @result.vpcs << vpc_h
      end

      def resource_record_set(rrset_name, type, &block)
        if rrset_name.sub(/\.\Z/, '') !~ /#{Regexp.escape(@name.sub(/\.\Z/, ''))}\Z/i
          raise "Invalid ResourceRecordSet Name: #{rrset_name}"
        end

        @result.resource_record_sets << ResourceRecordSet.new(rrset_name, type, &block).result
      end
      alias rrset resource_record_set

      class ResourceRecordSet
        attr_reader :result

        def initialize(name, type, &block)
          @result = OpenStruct.new({
            :name => name,
            :type => type,
          })

          instance_eval(&block)
        end

        private

        def set_identifier(value = nil)
          @result.set_identifier = value
        end
        alias identifier set_identifier

        def weight(value)
          @result.weight = value
        end

        def ttl(value)
          @result.ttl = value
        end

        def region(value)
          @result.region = value
        end

        def dns_name(value, options = {})
          options = Aws::Route53.normalize_dns_name_options(options)
          @result.dns_name = [value, options]
        end

        def geo_location(value)
          @result.geo_location = value
        end

        def failover(value)
          @result.failover = value
        end

        def health_check(url, *options)
          config = HealthCheck.parse_url(url)

          if options.length == 1 and options.first.kind_of?(Hash)
            options = options.first

            {
              :host              => :fully_qualified_domain_name,
              :search_string     => :search_string,
              :request_interval  => :request_interval,
              :failure_threshold => :failure_threshold,
              :measure_latency   => :measure_latency,
              :inverted          => :inverted
            }.each do |option_key, config_key|
              config[config_key] = options[option_key] if options[option_key]
            end
          else
            options.each_with_index do |value, i|
              key = [
                :fully_qualified_domain_name,
                :search_string,
                :request_interval,
                :failure_threshold,
                :measure_latency,
                :inverted
              ][i]

              config[key] = value
            end
          end

          if config.search_string
            config.type += '_STR_MATCH'
          end

          config.request_interval  ||= 30
          config.failure_threshold ||= 3
          config.measure_latency   ||= false
          config.inverted          ||= false

          @result.health_check = config
        end

        def resource_records(*values)
          if values.uniq.length != values.length
            raise "Duplicate ResourceRecords: #{values.join(', ')}"
          end

          @result.resource_records = [values].flatten.map {|i| Aws::Route53::Types::ResourceRecord.new(:value => i) }
        end

      end # ResourceRecordSet

    end # HostedZone

  end # DSL
end # RoadWorker
