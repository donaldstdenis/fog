require File.expand_path(File.join(File.dirname(__FILE__), '..', 'hp'))
require 'fog/storage'

module Fog
  module Storage
    class HP < Fog::Service

      requires    :hp_secret_key, :hp_account_id, :hp_tenant_id, :hp_avl_zone
      recognizes  :hp_auth_uri, :hp_servicenet, :hp_cdn_ssl, :hp_cdn_uri, :persistent, :connection_options, :hp_use_upass_auth_style, :hp_auth_version, :user_agent

      model_path 'fog/hp/models/storage'
      model       :directory
      collection  :directories
      model       :file
      collection  :files

      request_path 'fog/hp/requests/storage'
      request :delete_container
      request :delete_object
      request :get_container
      request :get_containers
      request :get_object
      request :get_object_temp_url
      request :head_container
      request :head_containers
      request :head_object
      request :put_container
      request :put_object

      module Utils

        def cdn
          unless @hp_cdn_uri.nil?
            @cdn ||= Fog::CDN.new(
              :provider       => 'HP',
              :hp_account_id  => @hp_account_id,
              :hp_secret_key  => @hp_secret_key,
              :hp_auth_uri    => @hp_auth_uri,
              :hp_cdn_uri     => @hp_cdn_uri,
              :hp_tenant_id   => @hp_tenant_id,
              :hp_avl_zone    => @hp_avl_zone,
              :connection_options => @connection_options
            )
            if @cdn.enabled?
              @cdn
            end
          else
            nil
          end
        end

        def url
          "#{@scheme}://#{@host}:#{@port}#{@path}"
        end

        def public_url(container=nil, object=nil)
          public_url = nil
          unless container.nil?
            if object.nil?
              # return container public url
              public_url = "#{url}/#{Fog::HP.escape(container)}"
            else
              # return object public url
              public_url = "#{url}/#{Fog::HP.escape(container)}/#{Fog::HP.escape(object)}"
            end
          end
          public_url
        end

        def perm_to_acl(perm, users=[])
          read_perm_acl = []
          write_perm_acl = []
          valid_public_perms  = ['pr', 'pw', 'prw']
          valid_account_perms = ['r', 'w', 'rw']
          valid_perms = valid_public_perms + valid_account_perms
          unless valid_perms.include?(perm)
            raise ArgumentError.new("permission must be one of [#{valid_perms.join(', ')}]")
          end
          # tackle the public access differently
          if valid_public_perms.include?(perm)
            case perm
              when "pr"
                read_perm_acl = [".r:*",".rlistings"]
              when "pw"
                write_perm_acl = ["*"]
              when "prw"
                read_perm_acl = [".r:*",".rlistings"]
                write_perm_acl = ["*"]
            end
          elsif valid_account_perms.include?(perm)
            # tackle the user access differently
            unless (users.nil? || users.empty?)
              # return the correct acls
              tenant_id = "*"  # this might change later
              acl_array = users.map { |u| "#{tenant_id}:#{u}" }
              #acl_string = acl_array.join(',')
              case perm
                when "r"
                  read_perm_acl = acl_array
                when "w"
                  write_perm_acl = acl_array
                when "rw"
                  read_perm_acl = acl_array
                  write_perm_acl = acl_array
              end
            end
          end
          return read_perm_acl, write_perm_acl
        end

        def perm_acl_to_header(read_perm_acl, write_perm_acl)
          header = {}
          if read_perm_acl.nil? && write_perm_acl.nil?
            header = {'X-Container-Read' => "", 'X-Container-Write' => ""}
          elsif !read_perm_acl.nil? && write_perm_acl.nil?
            header = {'X-Container-Read' => "#{read_perm_acl.join(',')}", 'X-Container-Write' => ""}
          elsif read_perm_acl.nil? && !write_perm_acl.nil?
            header = {'X-Container-Read' => "", 'X-Container-Write' => "#{write_perm_acl.join(',')}"}
          elsif !read_perm_acl.nil? && !write_perm_acl.nil?
            header = {'X-Container-Read' => "#{read_perm_acl.join(',')}", 'X-Container-Write' => "#{write_perm_acl.join(',')}"}
          end
          header
        end

        def header_to_perm_acl(read_header=nil, write_header=nil)
          read_h, write_h = nil
          read_h = read_header.split(',') unless read_header.nil?
          write_h = write_header.split(',') unless write_header.nil?
          return read_h, write_h
        end

        def generate_object_temp_url(container, object, expires_secs, method)
          return unless (container && object && expires_secs && method)

          # POST not allowed
          allowed_methods = %w{GET PUT HEAD}
          unless allowed_methods.include?(method)
            raise ArgumentError.new("Invalid method '#{method}' specified. Valid methods are: #{allowed_methods.join(', ')}")
          end

          expires = (Time.now + expires_secs.to_i).to_i

          # split up the storage uri
          uri = URI.parse(@hp_storage_uri)
          host   = uri.host
          path   = uri.path
          port   = uri.port
          scheme = uri.scheme

          # do not encode before signature generation, encode after
          sig_path = "#{path}/#{container}/#{object}"
          encoded_path = "#{path}/#{Fog::HP.escape(container)}/#{Fog::HP.escape(object)}"

          string_to_sign = "#{method}\n#{expires}\n#{sig_path}"
          signed_string = Digest::HMAC.hexdigest(string_to_sign, @hp_secret_key, Digest::SHA1)

          signature = @hp_tenant_id.to_s + ":" + @hp_account_id.to_s + ":" + signed_string
          signature = Fog::HP.escape(signature)

          # generate the temp url using the signature and expiry
          temp_url = "#{scheme}://#{host}:#{port}#{encoded_path}?temp_url_sig=#{signature}&temp_url_expires=#{expires}"
        end

      end

      class Mock
        include Utils
        def self.acls(type)
          type
        end

        def self.data
          @data ||= Hash.new do |hash, key|
            hash[key] = {
              :acls => {
                :container => {},
                :object => {}
              },
              :containers => {}
            }
            end
        end

        def self.reset
          @data = nil
        end

        def initialize(options={})
          require 'mime/types'
          @hp_secret_key = options[:hp_secret_key]
          @hp_account_id = options[:hp_account_id]
          @hp_tenant_id = options[:hp_tenant_id]
        end

        def data
          self.class.data[@hp_account_id]
        end

        def reset_data
          self.class.data.delete(@hp_account_id)
        end

      end

      class Real
        include Utils
        attr_reader :hp_cdn_ssl

        def initialize(options={})
          require 'mime/types'
          require 'multi_json'
          @hp_secret_key = options[:hp_secret_key]
          @hp_account_id = options[:hp_account_id]
          @hp_auth_uri   = options[:hp_auth_uri]
          @hp_cdn_ssl    = options[:hp_cdn_ssl]
          @connection_options = options[:connection_options] || {}
          ### Set an option to use the style of authentication desired; :v1 or :v2 (default)
          auth_version = options[:hp_auth_version] || :v2
          ### Pass the service name for object storage to the authentication call
          options[:hp_service_type] = "Object Storage"
          @hp_tenant_id = options[:hp_tenant_id]
          @hp_avl_zone  = options[:hp_avl_zone]

          ### Make the authentication call
          if (auth_version == :v2)
            # Call the control services authentication
            credentials = Fog::HP.authenticate_v2(options, @connection_options)
            # the CS service catalog returns the cdn endpoint
            @hp_storage_uri = credentials[:endpoint_url]
            @hp_cdn_uri  = credentials[:cdn_endpoint_url]
          else
            # Call the legacy v1.0/v1.1 authentication
            credentials = Fog::HP.authenticate_v1(options, @connection_options)
            # the user sends in the cdn endpoint
            @hp_storage_uri = options[:hp_auth_uri]
            @hp_cdn_uri  = options[:hp_cdn_uri]
          end

          @auth_token = credentials[:auth_token]

          uri = URI.parse(@hp_storage_uri)
          @host   = uri.host
          @path   = uri.path
          @persistent = options[:persistent] || false
          @port   = uri.port
          @scheme = uri.scheme

          @connection = Fog::Connection.new("#{@scheme}://#{@host}:#{@port}", @persistent, @connection_options)
        end

        def reload
          @connection.reset
        end

        def request(params, parse_json = true, &block)
          begin
            response = @connection.request(params.merge!({
              :headers  => {
                'Content-Type' => 'application/json',
                'X-Auth-Token' => @auth_token
              }.merge!(params[:headers] || {}),
              :host     => @host,
              :path     => "#{@path}/#{params[:path]}",
            }), &block)
          rescue Excon::Errors::HTTPStatusError => error
            raise case error
            when Excon::Errors::NotFound
              Fog::Storage::HP::NotFound.slurp(error)
            else
              error
            end
          end
          if !response.body.empty? && parse_json && response.headers['Content-Type'] =~ %r{application/json}
            response.body = MultiJson.decode(response.body)
          end
          response
        end

      end
    end
  end
end
