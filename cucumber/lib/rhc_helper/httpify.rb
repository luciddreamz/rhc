require 'rubygems'
require 'uri'
require 'net/https'
require 'ostruct'

module RHCHelper
  module Httpify
    include Loggable

    # attributes that contain statistics based on calls to connect
    attr_accessor :response_code, :response_time

    def http_instance(uri, timeout=30)
      proxy = ENV['http_proxy'] ? URI.parse(ENV['http_proxy']) : OpenStruct.new
      http = Net::HTTP.new(uri.host, uri.port, proxy.host, proxy.port)
      http.open_timeout = timeout
      http.read_timeout = timeout
      if (uri.scheme == "https")
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      end
      return http.start
    end

    def do_http(options)
      # Generate the URL if it doesn't exist
      options[:url] ||= "http%s://%s" % [options[:use_https] ? 's' : '', hostname]

      # Set some default options
      http_defaults = {
        :method   => :head,
        :host     => nil,
        :expected => Net::HTTPSuccess,
        :sleep    => 5,
        :timeout  => 1200,
        :http_timeout => 30,
        :follow_redirects => true,
        :redirects => 0,
        :max_redirects => 10
      }
      options = http_defaults.merge(options)

      # Parse the URI
      uri = URI.parse(options[:url])
      # Start with a nil response
      response = nil

      # Set some headers
      headers = {}
      headers['Host'] = host if options[:host]

      # Keep retrying, and let Ruby handle the timeout
      start   = Time.now

      # Helper function to log message and sleep
      def my_sleep(status,expected,start,options)
        [
          ["Expecting", expected.class],
          ["Received", status.class ],
          ["Elapsed", Time.now - start ],
        ].each do |values|
            logger.info "%10s: %s" % values
          end
        sleep options[:sleep]
      end

      expected = options[:expected]
      expected = (expected.to_s =~ /^Net/) ? expected.new(nil,nil,nil) : expected.new

      begin
        timeout(options[:timeout]) do
          loop do
            logger.debug "HTTP_CHECK: Requesting: #{uri}"
            # Send the HTTP request
            response = begin
                         http = http_instance(uri,options[:http_timeout])
                         http.send_request(
                           options[:method].to_s.upcase, # Allow options to be a symbol
                           uri.request_uri, nil, headers
                         )
                       rescue Exception => e
                         # Pass these up so we can check them
                         e
                       end
            logger.debug "HTTP_CHECK: Response: #{response.class}"
            case response
              # Catch any response if we're expecting it or redirection
            when expected.class, Net::HTTPRedirection
              break
              # Retry these responses
            when Net::HTTPServiceUnavailable, SocketError, Timeout::Error
              logger.debug "HTTP_CHECK: Error #{response.message}"
              my_sleep(response,expected,start,options)
            else
              case expected
              when Net::HTTPServiceUnavailable
                my_sleep(response,expected,start,options)
              else
                break
              end
            end
          end
        end
      rescue Timeout::Error => e
        puts "Did not receive an acceptable response in %d seconds" % options[:timeout]
      end

      # Test to see if we should follow redirect
      if options[:follow_redirects] && response.is_a?(Net::HTTPRedirection) && !(response.is_a?(options[:expected]))
        logger.debug "Response was a redirect, we will attempt to follow"
        logger.debug "We've been redirected #{options[:redirects]} times"
        if options[:redirects] < options[:max_redirects]
          options[:redirects] += 1
          response = do_http(options.merge({
            :url => response.header['location']
          }))
        else
          logger.debug "Too many redirects"
        end
      end

      return response
    end

    def is_inaccessible?(options = {})
      check_response(options.merge({
        :expected => Net::HTTPServiceUnavailable,
        :http_timeout => 2,
        :timeout => 60,
      }))
    end

    def is_accessible?(options = {})
      check_response(options.merge({
        :expected => Net::HTTPSuccess,
        :http_timeout => 20,
        :timeout => 180,
      }))
    end

    def doesnt_exist?
      check_response({
        :expected => SocketError,
      }) do |response|
          return !(response.is_a?(Net::HTTPSuccess))
        end
    end

    def check_response(options)
      response = do_http(options)

      if block_given?
        # Use the custom check for this response
        yield response
      else
        # Compare the response against :expected or Net::HTTPSuccess
        response.is_a?(options[:expected] || Net::HTTPSuccess)
      end
    end

    def connect(use_https=false, max_retries=30)
      prefix = use_https ? "https://" : "http://"
      url = prefix + hostname

      logger.info("Connecting to #{url}")
      beginning_time = Time.now

      response = do_http({
        :method => :get,
        :url => url,
        :http_timeout => 1
      })

      if response.is_a? Net::HTTPSuccess
        @response_code = response.code
        @response_time = Time.now - beginning_time
        logger.info("Connection result = #{@response_code} / #{url}")
        logger.info("Connection response time = #{@response_time} / #{url}")
        return response.body
      else
        logger.info("Connection failed / #{url}")
        return nil
      end
    end
  end
end
