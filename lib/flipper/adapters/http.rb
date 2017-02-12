require 'net/http'
require 'json'
require 'set'
require 'flipper'
require 'flipper/adapters/http/error'
require 'flipper/adapters/http/client'

module Flipper
  module Adapters
    class Http
      include Flipper::Adapter

      attr_reader :name

      def initialize(options = {})
        @client = Client.new(uri: options.fetch(:uri),
                             headers: options[:headers],
                             basic_auth_username: options[:basic_auth_username],
                             basic_auth_password: options[:basic_auth_password],
                             read_timeout: options[:read_timeout],
                             open_timeout: options[:open_timeout])
        @name = :http
      end

      def get(feature)
        response = @client.get("/features/#{feature.key}")
        raise Error, response unless response.is_a?(Net::HTTPOK)

        parsed_response = JSON.parse(response.body)
        result_for_feature(feature, parsed_response.fetch('gates'))
      end

      def add(feature)
        body = JSON.generate(name: feature.key)
        response = @client.post('/features', body)
        response.is_a?(Net::HTTPOK)
      end

      def get_multi(features)
        csv_keys = features.map(&:key).join(',')
        response = @client.get("/features?keys=#{csv_keys}")
        raise Error, response unless response.is_a?(Net::HTTPOK)

        parsed_response = JSON.parse(response.body)
        parsed_features = parsed_response.fetch('features')
        gates_by_key = parsed_features.each_with_object({}) do |parsed_feature, hash|
          hash[parsed_feature['key']] = parsed_feature['gates']
          hash
        end

        result = {}
        features.each do |feature|
          result[feature.key] = result_for_feature(feature, gates_by_key[feature.key])
        end
        result
      end

      def features
        response = @client.get('/features')
        raise Error, response unless response.is_a?(Net::HTTPOK)

        parsed_response = JSON.parse(response.body)
        parsed_response['features'].map { |feature| feature['key'] }.to_set
      end

      def remove(feature)
        response = @client.delete("/features/#{feature.key}")
        response.is_a?(Net::HTTPNoContent)
      end

      def enable(feature, gate, thing)
        body = request_body_for_gate(gate, thing.value.to_s)
        response = @client.post("/features/#{feature.key}/#{gate.key}", body)
        response.is_a?(Net::HTTPOK)
      end

      def disable(feature, gate, thing)
        body = request_body_for_gate(gate, thing.value.to_s)
        response = @client.delete("/features/#{feature.key}/#{gate.key}", body)
        response.is_a?(Net::HTTPOK)
      end

      def clear(feature)
        response = @client.delete("/features/#{feature.key}/boolean")
        response.is_a?(Net::HTTPOK)
      end

      private

      def request_body_for_gate(gate, value)
        data = case gate.key
               when :boolean
                 {}
               when :groups
                 { name: value }
               when :actors
                 { flipper_id: value }
               when :percentage_of_actors, :percentage_of_time
                 { percentage: value }
               else
                 raise "#{gate.key} is not a valid flipper gate key"
               end
        JSON.generate(data)
      end

      def result_for_feature(feature, api_gates)
        api_gates ||= []
        result = default_config

        feature.gates.each do |gate|
          api_gate = api_gates.detect { |ag| ag['key'] == gate.key.to_s }
          result[gate.key] = value_for_gate(gate, api_gate) if api_gate
        end

        result
      end

      def value_for_gate(gate, api_gate)
        value = api_gate['value']
        case gate.data_type
        when :boolean, :integer
          value ? value.to_s : value
        when :set
          value ? value.to_set : Set.new
        else
          unsupported_data_type(gate.data_type)
        end
      end

      def unsupported_data_type(data_type)
        raise "#{data_type} is not supported by this adapter"
      end
    end
  end
end
