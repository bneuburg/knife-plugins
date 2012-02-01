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
    class RoleSecretAdd < Knife

      deps do
        require 'openssl'
        require 'base64'
      end
      
      banner "knife role secret add [ROLE] [PLAINTEXT] [ATTRIBUTE]"

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
      :description => "TYPE is either default, normal, override. Default value is normal."

      def run
        unless name_args.length == 3
          show_usage
          exit 1
        else
          @rolename = @name_args[0]
          @plaintext = @name_args[1]
          @attribute = @name_args[2]
        end

        @type = config[:attribute_type] || "normal"

        # Build the query
        query = "role:#{@rolename}"
        q = Chef::Search::Query.new

        # @nodes contains the name of all nodes that are of role @rolename
        @nodes = []
        q.search(:node, query).each do |el|
          if el.class == Array
            el.each do |node|
              @nodes << node.name
            end
          end
        end
        
        # We need to encrypt the secret for each of them, since their private key differs
        @nodes.each do |n|

          client = Chef::ApiClient.load(n)
          @encryption_key = OpenSSL::PKey::RSA.new(client.public_key)

          @encrypted_string = Base64.encode64(@encryption_key.public_encrypt(@plaintext))
          @node = Chef::Node.load(n)

          if config[:print_ciphertext]
            output "Ciphertext for node #{@nodename} is #{@encrypted_string}."
          end

          mash = Mash.new

          mash.nested_mash_with_value(@attribute.split('.'), @encrypted_string)

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
end

