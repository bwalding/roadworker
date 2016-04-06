module Roadworker
  class HealthCheck

    class << self
      def health_checks(route53, options = {})
        self.new(route53).health_checks(options)
      end

      def gc(route53, options = {})
        self.new(route53).gc(options)
      end

      def config_to_hash(config)
        ipaddr = config[:ip_address]
        port   = config[:port]
        type   = config[:type].downcase
        path   = config[:resource_path]
        fqdn   = config[:fully_qualified_domain_name]
        fqdn   = fqdn.downcase if fqdn
        search_string     = config[:search_string]
        request_interval  = config[:request_interval]
        failure_threshold = config[:failure_threshold]
        measure_latency   = config[:measure_latency]
        inverted          = config[:inverted]

        ulr = nil

        if ipaddr
          url = "#{type}://#{ipaddr}:#{port}"
        else
          url = "#{type}://#{fqdn}:#{port}"
          fqdn = nil
        end

        url << path if path && path != '/'

        {
          :url               => url,
          :host              => fqdn,
          :search_string     => search_string,
          :request_interval  => request_interval,
          :failure_threshold => failure_threshold,
          :measure_latency   => measure_latency,
          :inverted          => inverted
        }
      end

      def parse_url(url)
        url = URI.parse(url)
        path = url.path

        if path.nil? or path.empty? or path == '/'
          path = nil
        end

        config = Aws::Route53::Types::HealthCheckConfig.new

        {
          :port          => url.port,
          :type          => url.scheme.upcase,
          :resource_path => path,
        }.each {|key, value|
          config[key] = value if value
        }

        if url.host =~ /\A\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\Z/
          config.ip_address = url.host
        else
          config.fully_qualified_domain_name = url.host
        end

        return config
      end
    end # of class method

    def initialize(route53)
      @route53 = route53
    end

    def health_checks(options = {})
      check_list = {}

      is_truncated = true
      next_marker = nil

      while is_truncated
        opts = next_marker ? {:marker => next_marker} : {}
        response = @route53.list_health_checks(opts)

        response[:health_checks].each do |check|
          check_list[check[:id]] = check[:health_check_config]
        end

        is_truncated = response[:is_truncated]
        next_marker = response[:next_marker]
      end

      if options[:extended]
        check_list.instance_variable_set(:@route53, @route53)

        def check_list.find_or_create(attrs)
          health_check_id, config = self.find {|hcid, elems| elems == attrs }

          unless health_check_id
            response = @route53.create_health_check({
              :caller_reference    => UUID.new.generate,
              :health_check_config => attrs,
            })

            health_check_id = response[:health_check][:id]
            config = response[:health_check][:health_check_config]
            self[health_check_id] = config
          end

          return health_check_id
        end
      end

      return check_list
    end

    def gc(options = {})
      check_list = health_checks
      return if check_list.empty?

      if (logger = options[:logger])
        logger.info('Clean HealthChecks (pass `--no-health-check-gc` if you do not want to clean)')
      end

      Collection.batch(@route53.list_hosted_zones, :hosted_zones) do |zone|
        Collection.batch(@route53.list_resource_record_sets(hosted_zone_id: zone.id), :resource_record_sets) do |record|
          check_list.delete(record.health_check_id)
        end
      end

      check_list.each do |health_check_id, config|
        @route53.delete_health_check(:health_check_id  => health_check_id)
      end
    end

  end # HealthCheck
end # Roadworker
