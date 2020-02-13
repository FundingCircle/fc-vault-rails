require "active_support/concern"

module Vault
  module Legacy
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
        # @option options [Bool] :convergent
        #   use convergent encryption (default: +false+)
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
        def vault_attribute(attribute, options = {})
          encrypted_column = options[:encrypted_column] || "#{attribute}_encrypted"
          encrypted_copy = options[:encrypted_copy]
          path = options[:path] || "transit"
          key = options[:key] || "#{Vault::Rails.application}_#{table_name}_#{attribute}"
          convergent = options.fetch(:convergent, false)

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

          unless serializer
            serializer = Vault::Rails::Serializers::StringSerializer
          end

          # Getter
          define_method("#{attribute}") do
            if instance_variable_defined?("@#{attribute}")
              return instance_variable_get("@#{attribute}")
            end

            __vault_load_attribute!(attribute, self.class.__vault_attributes[attribute])
          end

          # Setter
          define_method("#{attribute}=") do |value|
            cast_value = cast_value_to_type(options, value)
            # We always set it as changed without comparing with the current value
            # because we allow our held values to be mutated, so we need to assume
            # that if you call attr=, you want it send back regardless.
            attribute_will_change!("#{attribute}")
            instance_variable_set("@#{attribute}", cast_value)
          end

          # Checker
          define_method("#{attribute}?") do
            send("#{attribute}").present?
          end

          # Dirty method
          define_method("#{attribute}_change") do
            changes["#{attribute}"]
          end

          # Dirty method
          define_method("#{attribute}_changed?") do
            changed.include?("#{attribute}")
          end

          # Dirty method
          define_method("#{attribute}_was") do
            if changes["#{attribute}"]
              changes["#{attribute}"][0]
            else
              public_send("#{attribute}")
            end
          end

          # Encrypted copy serialization
          if encrypted_copy
            serialize :encryption_metadata, JSON
          end

          # Make a note of this attribute so we can use it in the future (maybe).
          __vault_attributes[attribute.to_sym] = {
            key: key,
            path: path,
            serializer: serializer,
            encrypted_column: encrypted_column,
            encrypted_copy: encrypted_copy,
            convergent: convergent
          }

          self
        end

        # Encrypt Vault attributes before saving them
        def vault_persist_before_save!
          skip_callback :save, :after, :__vault_persist_attributes!
          before_save :__vault_encrypt_attributes!
        end

        # Define proxy getter and setter methods
        #
        # Override the getter and setter for a particular non-encrypted attribute
        # so that they also call the getter/setter of the encrypted one.
        # This ensures that all the code that uses the attribute in question
        # also updates/retrieves the encrypted value whenever it is available.
        #
        # This method is useful if you have a plaintext attribute that you want to replace with a vault attribute.
        # During a transition period both attributes can be seamlessly read/changed at the same time.
        #
        # @param [String | Symbol] non_encrypted_attribute
        #   The name of original attribute (non-encrypted).
        # @param [String | Symbol] encrypted_attribute
        #   The name of the encrypted attribute.
        #   This makes sure that the encrypted attribute behaves like a real AR attribute.
        # @param [Boolean] (false) encrypted_attribute_only
        #   Whether to read and write to both encrypted and non-encrypted attributes.
        #   Useful for when we stop using the non-encrypted one.
        def vault_attribute_proxy(non_encrypted_attribute, encrypted_attribute, options={})
          if options[:type].present?
            ActiveSupport::Deprecation.warn('The `type` option on `vault_attribute_proxy` is now ignored.  To specify type information you should move the `type` option onto the `vault_attribute` definition.')
          end
          # Only return the encrypted attribute if it's available and encrypted_attribute_only is true.
          define_method(non_encrypted_attribute) do
            return send(encrypted_attribute) if options[:encrypted_attribute_only]

            send(encrypted_attribute) || super()
          end

          # Update only the encrypted attribute if encrypted_attribute_only is true and both attributes otherwise.
          define_method("#{non_encrypted_attribute}=") do |value|
            super(value) unless options[:encrypted_attribute_only]

            send("#{encrypted_attribute}=", value)
          end
        end

        # The list of Vault attributes.
        #
        # @return [Hash]
        def __vault_attributes
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

          if options[:encrypted_copy]
            if options[:encrypted_copy][:column].nil? || options[:encrypted_copy][:key].nil?
              raise Vault::Rails::ValidationFailedError, "Cannot specify " \
                "`:encrypted_copy` with missing `:column` or `:key`"
            end
          end
        end

        def vault_lazy_decrypt?
          !!@vault_lazy_decrypt
        end

        def vault_lazy_decrypt!
          @vault_lazy_decrypt = true
        end

        # works only with convergent encryption
        def vault_persist_all(attribute, records, plaintexts, validate: true)
          options = __vault_attributes[attribute]

          Vault::PerformInBatches.new(attribute, options).encrypt(records, plaintexts, validate: validate)
        end

        # works only with convergent encryption
        # relevant only if lazy decryption is enabled
        def vault_load_all(attribute, records)
          options = __vault_attributes[attribute]

          Vault::PerformInBatches.new(attribute, options).decrypt(records)
        end

        def encrypt_attribute(attribute, value)
          encrypt_value(value, __vault_attributes[attribute])
        end

        def encrypt_value(value, options)
          key        = options[:key]
          path       = options[:path]
          serializer = options[:serializer]
          convergent = options[:convergent]

          plaintext = serializer.encode(value)

          Vault::Rails.encrypt(path, key, plaintext, Vault.client, convergent)
        end

        def encrypted_find_by(attributes)
          find_by(search_options(attributes))
        end

        def encrypted_find_by!(attributes)
          find_by!(search_options(attributes))
        end

        def encrypted_where(attributes)
          where(search_options(attributes))
        end

        def encrypted_where_not(attributes)
          where.not(search_options(attributes))
        end

        private

        def search_options(attributes)
          {}.tap do |search_options|
            attributes.each do |attribute_name, attribute_value|
              attribute_options = __vault_attributes[attribute_name]
              encrypted_column = attribute_options[:encrypted_column]

              unless attribute_options[:convergent]
                raise ArgumentError, 'You cannot search with non-convergent fields'
              end

              search_options[encrypted_column] = encrypt_attribute(attribute_name, attribute_value)
            end
          end
        end
      end

      included do
        # After a resource has been initialized, immediately communicate with
        # Vault and decrypt any attributes unless vault_lazy_decrypt is set.
        after_initialize :__vault_load_attributes!

        # After we save the record, persist all the values to Vault and reload
        # them attributes from Vault to ensure we have the proper attributes set.
        # The reason we use `after_save` here is because a `before_save` could
        # run too early in the callback process. If a user is changing Vault
        # attributes in a callback, it is possible that our callback will run
        # before theirs, resulting in attributes that are not persisted.
        after_save :__vault_persist_attributes!

        # Decrypt all the attributes from Vault.
        # @return [true]
        def __vault_load_attributes!
          return if self.class.vault_lazy_decrypt?

          self.class.__vault_attributes.each do |attribute, options|
            self.__vault_load_attribute!(attribute, options)
          end
        end

        def attributes
          super.tap do |attrs|
            missing_keys = self.class.__vault_attributes.keys.map(&:to_s) - attrs.keys
            missing_keys.each do |key|
              attrs.store(key, public_send(key))
            end
          end
        end

        # Decrypt and load a single attribute from Vault.
        def __vault_load_attribute!(attribute, options)
          key        = options[:key]
          path       = options[:path]
          serializer = options[:serializer]
          column     = options[:encrypted_column]
          convergent = options[:convergent]

          # Load the ciphertext
          ciphertext = read_attribute(column)

          # If the user provided a value for the attribute, do not try to load it from Vault
          return if instance_variable_get("@#{attribute}")

          # Load the plaintext value
          plaintext = Vault::Rails.decrypt(path, key, ciphertext, Vault.client, convergent)

          # Deserialize the plaintext value, if a serializer exists
          plaintext = serializer.decode(plaintext) if serializer

          # Write the virtual attribute with the plaintext value
          instance_variable_set("@#{attribute}", plaintext)
        end

        def cast_value_to_type(options, value)
          type_constant_name = options.fetch(:type, :value).to_s.camelize
          type = ActiveRecord::Type.const_get(type_constant_name).new

          if type.respond_to?(:type_cast_from_user)
            type.type_cast_from_user(value)
          else
            value
          end
        end

        # Encrypt all the attributes using Vault and set the encrypted values back
        # on this model.
        # @return [true]
        def __vault_persist_attributes!
          changes = __vault_encrypt_attributes!
          changes[:encryption_metadata] = encryption_metadata if attribute_changed?(:encryption_metadata)
          # If there are any changes to the model, update them all at once,
          # skipping any callbacks and validation. This is okay, because we are
          # already in a transaction due to the callback.
          self.update_columns(changes) if !changes.empty?

          true
        end

        def __vault_encrypt_attributes!
          changes = {}

          self.class.__vault_attributes.each do |attribute, options|
            if change = self.__vault_encrypt_attribute!(attribute, options)
              changes.merge!(change)
            end
          end

          changes
        end

        # Encrypt a single attribute using Vault and persist back onto the
        # encrypted attribute value.
        def __vault_encrypt_attribute!(attribute, options)
          # Only persist changed attributes to minimize requests - this helps
          # minimize the number of requests to Vault.
          return unless changed.include?("#{attribute}")

          column = options[:encrypted_column]

          # Get the current value of the plaintext attribute
          plaintext = instance_variable_get("@#{attribute}")

          # Generate the ciphertext and store it back as an attribute
          ciphertext = self.class.encrypt_attribute(attribute, plaintext)

          # Write the attribute back, so that we don't have to reload the record
          # to get the ciphertext
          write_attribute(column, ciphertext)

          # Return the updated column so we can save
          result = { column => ciphertext }

          if options[:encrypted_copy]
            encryption_metadata = __vault_find_or_create_encryption_metadata_for(options[:encrypted_copy])

            encrypted_copy_options = { key: encryption_metadata['encryption_key_name'], convergent: false }
            encryption_options = self.class.__vault_attributes[attribute].merge(encrypted_copy_options)
            copy_ciphertext = self.class.encrypt_value(plaintext, encryption_options)
            copy_column = options[:encrypted_copy][:column]

            write_attribute(copy_column, copy_ciphertext)
            result[copy_column] = copy_ciphertext
          end

          result
        end

        def unencrypted_attributes
          encrypted_attributes = self.class.__vault_attributes.values.flat_map do |x|
            [x[:encrypted_column].to_s].tap do |result|
              result << x[:encrypted_copy][:column] if x[:encrypted_copy]
            end
          end

          attributes.delete_if { |attribute| encrypted_attributes.include?(attribute) }
        end

        # Override the reload method to reload the Vault attributes. This will
        # ensure that we always have the most recent data from Vault when we
        # reload a record from the database.
        def reload(*)
          super.tap do
            # Unset all the instance variables to force the new data to be pulled from Vault
            self.class.__vault_attributes.each do |attribute, _|
              if instance_variable_defined?("@#{attribute}")
                self.remove_instance_variable("@#{attribute}")
              end
            end

            self.__vault_load_attributes!
          end
        end

        def __vault_find_or_create_encryption_metadata_for(options)
          encryption_metadata = read_attribute(:encryption_metadata) || []
          field_path = options[:field_json_path] || "$.#{options[:column]}"

          attribute_metadata = encryption_metadata.find do |attribute_metadata|
            attribute_metadata['field_path'] == field_path
          end

          return attribute_metadata if attribute_metadata

          key = case options[:key]
                when Symbol
                  self.send(options[:key])
                when Proc
                  self.instance_exec &options[:key]
                when String
                  options[:key]
                end

          attribute_metadata = { 'field_path' => field_path, 'encryption_key_name' => key }
          encryption_metadata << attribute_metadata
          self.encryption_metadata = encryption_metadata

          attribute_metadata
        end
      end
    end
  end
end
