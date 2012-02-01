require 'chef/knife'

class Mash < Hash

  def nested_mash_with_value(array, value)
    node = self
    array.each_with_index do |e, i|
      if node[e].nil?
        if i == array.length - 1
          node[e] = value
        else
          node[e] = Mash.new
        end
      end
      node = node[e]
    end
    self
  end
  
end


class Chef
  class Knife
    class NodeSecretAdd < Knife

      deps do
        require 'openssl'
        require 'base64'
      end
      
      banner "knife node secret add [NODE] [PLAINTEXT] [ATTRIBUTE]"

      option :print_ciphertext,
      :short => "-p",
      :long => "--print-ciphertext",
      :boolean => true,
      :description => "Also print the ciphertext to STDOUT"

      option :dry_run,
      :short => "-d",
      :long => "--dry-run",
      :boolean => true,
      :description => "Just check what would be done"

      option :attribute_type,
      :short => "-t TYPE",
      :long => "--attribute-type TYPE",
      :description => "TYPE is one of default, normal, override. Default value is normal."

      option :client_name,
      :short => "-x CLIENT",
      :long => "--client-name CLIENT",
      :description => "Use public key of CLIENT to encrypt. Useful if nodename != clientname."


      def run

        # Check for roght amount of arguments
        unless name_args.length == 3
          show_usage
          exit 1
        else
          @nodename = @name_args[0]
          @plaintext = @name_args[1]
          @attribute = @name_args[2]
        end


        # Default to normal for attribute type
        @type = config[:attribute_type] || "normal"

        # Exit if an invalid attribute type was passed
        unless ['default', 'normal', 'override'].include? @type
          ui.fatal "#{@type} is not a valid attribute type."
          ui.fatal "Use either default, normal or override."
          exit 1
        end


        # For encryption we need a key. Therefore we need a client linked to
        # the node and look up that client's public key.

        # By default, it is assumed that the client we look for has the same
        # name as the node.
        
        # If node and client names do not match, one can use the client_name option.

        # Unless that option is used, we fall back to the node name
        @clientname = config[:client_name] || @nodename

        client = Chef::ApiClient.load(@clientname)
        @encryption_key = OpenSSL::PKey::RSA.new(client.public_key)

        # First we encrypt the secret, then we encode it in base64 to avoid
        # troublesome characters on the Chef server and in CouchDB
        
        @encrypted_string = Base64.encode64(@encryption_key.public_encrypt(@plaintext))

        # Now we need to load the node, since this is the object we want to modify
        @node = Chef::Node.load(@nodename)

        # Print out the ciphertext before continuing if it was demanded
        if config[:print_ciphertext]
          output "Ciphertext for node #{@nodename} is #{@encrypted_string}."
        end

        # We build a Mash which we will deep merge later.
        # All keys in the passed attribute will be set to a Mash, except
        # the last one, which will be a string, in this case the ciphertext
        mash = Mash.new
        mash.nested_mash_with_value(@attribute.split('.'), @encrypted_string)

        # Last but not least we try to determine the current value for the attribute
        # that would possibly be overwritten

        current_value = @node.send("#{@type}_attrs")
        @attribute.split('.').each do |part|
          unless current_value.respond_to? :has_key?
            ui.fatal "A sub path of attribute #{@attribute} seems not to be a Mash or Hash."
            ui.fatal "Inspected object: \n #{current_value.inspect}."
            ui.fatal "Exiting to avoid messing up the attribute tree."
            exit 1
          end
          if current_value.has_key? part
            current_value = current_value[part]
          else
            current_value = nil
            break
          end
        end

        dryrun_message = "Current value is:\n #{current_value}."
        dryrun_message = "Currently this value is not set." unless current_value
        
	if config[:dry_run]
          # Only output what would have been done
          output "This would set #{@attribute} on node #{@nodename} to:"
          output @encrypted_string
          output dryrun_message
        else
          Chef::Mixin::DeepMerge.deep_merge!(mash, @node.send("#{@type}_attrs"))
          @node.save
          output "Successfully set attribute #{@attribute} on node #{@nodename}."
        end
        
      end
    end
  end
end

