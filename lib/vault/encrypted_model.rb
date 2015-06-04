require "active_support/concern"

module Vault
  module EncryptedModel
    extend ActiveSupport::Concern

    module ClassMethods
      # Creates an attribute that is read and written using Vault.
      #
      # @example
      #
      #   class Person < ActiveRecord::Base
      #     include Vault::EncryptedModel
      #     vault_attribute :ssn
      #   end
      #
      #   person = Person.new
      #   person.ssn = "123-45-6789"
      #   person.save
      #   person.encrypted_ssn #=> "vault:v0:6hdPkhvyL6..."
      #
      # @param [Symbol] column
      #   the column that is encrypted
      # @param [Hash] options
      #
      # @option options [Symbol] :encrypted_column
      #   the name of the encrypted column (default: +#{column}_encrypted+)
      # @option options [String] :path
      #   the path to the transit backend (default: +transit+)
      # @option options [String] :key
      #   the name of the encryption key (default: +#{app}_#{table}_#{column}+)
      # @option options [Symbol, Class] :serializer
      #   the name of the serializer to use (or a class)
      # @option options [Proc] :encode
      #   a proc to encode the value with
      # @option options [Proc] :decode
      #   a proc to decode the value with
      def vault_attribute(column, options = {})
        encrypted_column = options[:encrypted_column] || "#{column}_encrypted"
        path = options[:path] || "transit"
        key = options[:key] || "#{Vault::Rails.application}_#{table_name}_#{column}"

        # Sanity check options!
        _vault_validate_options!(options)

        # Get the serializer if one was given.
        serializer = options[:serialize]

        # Unless a class or module was given, construct our serializer. (Slass
        # is a subset of Module).
        if serializer && !serializer.is_a?(Module)
          serializer = Vault::Rails.serializer_for(serializer)
        end

        # See if custom encoding or decoding options were given.
        if options[:encode] && options[:decode]
          serializer = Class.new
          serializer.define_singleton_method(:encode, &options[:encode])
          serializer.define_singleton_method(:decode, &options[:decode])
        end

        # Getter
        define_method(column) do
          value = instance_variable_get(:"@#{column}")
          return value if !value.nil?

          ciphertext = read_attribute(encrypted_column)
          plaintext  = Vault::Rails.decrypt(path, key, ciphertext)
          plaintext  = serializer.decode(plaintext) if serializer

          instance_variable_set(:"@#{column}", plaintext)
        end

        # Setter
        define_method("#{column}=") do |plaintext|
          plaintext = serializer.encode(plaintext) if serializer

          ciphertext = Vault::Rails.encrypt(path, key, plaintext)
          write_attribute(encrypted_column, ciphertext)

          instance_variable_set(:"@#{column}", plaintext)
        end

        # Checker
        define_method("#{column}?") do
          read_attribute(encrypted_column).present?
        end

        # Make a note of this attribute so we can use it in the future (maybe).
        _vault_attributes.store(column.to_sym,
          encrypted_column: encrypted_column,
          path: path,
          key: key,
        )

        self
      end

      # The list of Vault attributes.
      #
      # @return [Hash]
      def _vault_attributes
        @vault_attributes ||= {}
      end

      # Validate that Vault options are all a-okay! This method will raise
      # exceptions if something does not make sense.
      def _vault_validate_options!(options)
        if options[:serializer]
          if options[:encode] || options[:decode]
            raise Vault::Rails::ValidationFailedError, "Cannot use a " \
              "custom encoder/decoder if a `:serializer' is specified!"
          end
        end

        if options[:encode] && !options[:decode]
          raise Vault::Rails::ValidationFailedError, "Cannot specify " \
            "`:encode' without specifying `:decode' as well!"
        end

        if options[:decode] && !options[:encode]
          raise Vault::Rails::ValidationFailedError, "Cannot specify " \
            "`:decode' without specifying `:encode' as well!"
        end
      end
    end
  end
end