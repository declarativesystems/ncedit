require 'puppetclassify'
require 'yaml'
require 'json'
require 'escort'
require 'puppet_https'

module NCEdit
  module Cmd
    DEFAULT_RULE = "or"

    R10K_SETTINGS_CLASS = "puppet_enterprise::profile::master"
    R10K_SETTINGS_PARAMS = [
        "code_manager_auto_configure",
        "r10k_remote",
        "r10k_private_key",
        "r10k_proxy",
        "r10k_postrun",
    ]

    def self.init(puppetclassify = nil)
      if puppetclassify
        # use passed in puppetclassify if present - allows injection for easy
        # tesing - otherwise make a real one
        @puppetclassify = puppetclassify
      else
        hostname = %x(facter fqdn).strip.downcase
        port = 4433


        # Define the url to the classifier API - we can't just do localhost because
        # the name has to match the SSL certificate
        base_url = "https://#{hostname}:"
        @puppet_url = "#{base_url}8140"
        @rest_api_url = "#{base_url}#{port}/classifier-api"

        # We need to authenticate against the REST API using a certificate
        # that is whitelisted in /etc/puppetlabs/console-services/rbac-certificate-whitelist.
        # (https://docs.puppetlabs.com/pe/latest/nc_forming_requests.html#authentication)
        #
        # Since we're doing this on the master,
        # we can just use the internal dashboard certs for authentication
        ssl_dir     = '/etc/puppetlabs/puppet/ssl'
        ca_cert     = "#{ssl_dir}/ca/ca_crt.pem"
        cert_name   = hostname.downcase
        cert        = "#{ssl_dir}/certs/#{cert_name}.pem"
        private_key = "#{ssl_dir}/private_keys/#{cert_name}.pem"

        auth_info = {
          'ca_certificate_path' => ca_cert,
          'certificate_path'    => cert,
          'private_key_path'    => private_key,
        }

        # wait upto 5 mins for classifier to become live...
        port_open = false
        Timeout::timeout(300) do
          while not port_open
            begin
              s = TCPSocket.new(hostname, port)
              s.close
              port_open = true
              Escort::Logger.output.puts "Classifier signs of life detected, proceeding to classify..."
            rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
              Escort::Logger.output.puts "connection refused, waiting..."
              sleep(1)
            end
          end
        end

        @puppetclassify = PuppetClassify.new(@rest_api_url, auth_info)

        # borrow the cool HTTPS requester built into puppetclassify
        @puppet_https = PuppetHttps.new(auth_info)
      end
    end

    # Fetch a group by ID, make the group if it doesn't already exist
    def self.nc_group_id(group_name, parent_name: "All Nodes")
      if ! @puppetclassify
        init
      end

      group_id  = @puppetclassify.groups.get_group_id(group_name)
      if group_id == nil
        Escort::Logger.output.puts "Group: #{group_name} does not exist, creating..."
        res = @puppetclassify.groups.create_group(
          {
            "name"    => group_name,
            "parent"  => @puppetclassify.groups.get_group_id(parent_name),
            "classes" => {},
          }
        )
        if res == nil
          raise "Error creating group #{group_name}"
        end

        # re-fetch the group id
        group_id  = @puppetclassify.groups.get_group_id(group_name)
      end

      group_id
    end

    def self.nc_group(group_name, parent_name:nil)
      if ! @puppetclassify
        init
      end
      # Get the wanted group from the API
      #   1. Get the id of the wanted group
      #   2. Use the id to fetch the group
      group_id = nc_group_id(group_name, parent_name: parent_name)
      Escort::Logger.output.puts "Group #{group_name} found, getting definition"
      group = @puppetclassify.groups.get_group(group_id)

      group
    end

    # to see if our changes were saved or not we need to remove all nillified
    # keys from both levels (class, parameter) of the class_delta array, since
    # when we re-read from the NC our nillified data will be completely gone.  A
    # naive comparison would then report a failure even though the operation
    # succeeded.  On a practical level we must convert:
    # {"puppet_enterprise"=>{"proxy"=>nil, "keep"=>"keep"}, "b"=>nil}
    # ...to...
    # {"puppet_enterprise"=>{"keep"=>"keep"}}
    #
    # @param nc_class The class hash as re-read from the NC API
    # @param class_delta The class delta we originally requested (with nils for deletes)
    def self.delta_saved?(nc_class, class_delta)
      class_delta_reformatted = class_delta.map { |class_name, params|
        if params == nil
          # skip classes that are requested to be deleted for the moment since
          # we will catch them on the outer pass
      	  params_fixed = params
        else
          # remove all individual nullified parameters
      	  params_fixed = params.reject{|param_name, param_value| param_value == nil}
        end
        [class_name,params_fixed]
      }.to_h.reject { |class_name,params| params == nil}

      nc_class == class_delta_reformatted
    end

    def self.update_group(group_name, classes: nil, rule: nil, environment: nil, environment_trumps: nil)
      # group_delta will actually replace all classes/rules with whatever is
      # specified, so we need to merge this with any existing definition if
      # one of these fields is not needed for a particular update otherwise
      # updating just the classes would remove the current rule!
      if classes == nil
        classes = nc_group(group_name)["classes"]
      end

      if rule == nil
        rule = nc_group(group_name)["rule"]
      end

      if environment == nil
        environment = nc_group(group_name)["environment"]
      end

      if ! environment_trumps
        environment_trumps = nc_group(group_name)["environment_trumps"]
      end

      group_delta = {
        'id'                  => nc_group_id(group_name),
        'rule'                => rule,
        'classes'             => classes,
        'environment'         => environment,
        'environment_trumps'  => environment_trumps,
      }
      res = @puppetclassify.groups.update_group(group_delta)

      # due to the way the puppetclassify gem is written, we get a nil response
      # on every request, whether it passed or failed.  Therefore, to test that
      # our update was processed correctly, the only thing we can do is to fetch
      # the group again from puppetclassify and check that all of our values are
      # now present.  If there was an error, then the user should have
      # previously seen some output since puppetclassify prints some useful
      # debug output
      re_read_group = nc_group(group_name)
      if delta_saved?(re_read_group["classes"], classes) &&
          re_read_group["rule"] == rule &&
          re_read_group["environment"] == environment &&
          re_read_group["environment_trumps"] == environment_trumps
        Escort::Logger.output.puts "changes saved"
      else
        Escort::Logger.error.error "re-read #{group_name} results in #{re_read_group} should have delta of #{group_delta}"
        raise "Error saving #{group_name}"
      end
    end

    def self.read_batch_data(yaml_file: nil, json_file:nil)
      if yaml_file == nil and json_file == nil
        raise "YAML or JSON file must be specified for batch updates"
      elsif yaml_file and json_file
        raise "Cannot process both YAML and JSON at the same time"
      elsif yaml_file
        if File.exists?(yaml_file)
          begin
            data = YAML.load_file(yaml_file)
          rescue Psych::SyntaxError
            raise "syntax error parsing #{yaml_file}"
          end
        else
          raise "YAML file not found: #{yaml_file}"
        end
      elsif json_file
        if File.exists?(json_file)
          begin
            data = JSON.parse(IO.read(json_file))
          rescue JSON::ParserError
            raise "syntax error parsing #{json_file}"
          end
        else
          raise "JSON file not found: #{json_file}"
        end
      end
      data
    end

    # Batch entry from YAML file, example file format:
    # 'PE Master':
    #   'classes':
    #     'puppet_enterprise::profile::master':
    #       'r10k_remote': 'http://blah'
    #       'r10k_private_key': '/etc/topsecret'
    #
    #   'delete_classes':
    #      'puppet_enterprise::profile::masterbad'
    #
    #   'delete_params':
    #      'puppet_enterprise::profile::redo:
    #         'badparam'
    #
    # 'Puppet Masters':
    #   'classes':
    #     'role::puppet::master':
    #   'append_rules':
    #     - - "="
    #       - "name"
    #       - "vmpump02.puppet.com"
    def self.batch(yaml_file: nil, json_file: nil, smart_update: false)
      data = read_batch_data(yaml_file: yaml_file, json_file: json_file)

      if smart_update
        needs_reclassify = contains_r10k_settings(data)
        if needs_reclassify
          apply_r10k_settings_now(needs_reclassify)
        end
        puppet_code_deploy

        Escort::Logger.output.puts "Sleep for 60 seconds to let classes finish their refresh..."
        sleep(60)
      end

      data.each { |group_name, data|

        Escort::Logger.output.puts "Processing #{group_name}"
        group = nc_group(group_name)

        #
        # delete classes
        #
        if data.has_key?("delete_classes")
          changes = false

          data["delete_classes"].each { |class_name|
            changes |= ensure_class(group, class_name, delete:true)
          }
          if changes
            update_group(group_name, classes: group["classes"])
          end
        end

        #
        # delete params
        #
        if data.has_key?("delete_params")
          changes = false
          data["delete_params"].each { |class_name, delete_params|
            delete_params.each { | param_name|
              changes |= ensure_class(group, class_name)
              changes |= ensure_param(group, class_name, param_name, nil, delete:true)
            }
          }
          if changes
            update_group(group_name, classes: group["classes"])
          end
        end

        #
        # classes (and optionally params)
        #
        if data.has_key?("classes")
          if ensure_classes_and_params(group, data["classes"])
            update_group(group_name, classes: group["classes"])
          end
        end

        #
        # append rules
        #
        if data.has_key?("append_rules")
          if ensure_rules(group, data["append_rules"])
            update_group(group_name, rule: group["rule"])
          end
        end
      }
    end


    # Classes are only removed when they have their parameters nilled so we must
    # formulate special json to allow delete
    # @see https://docs.puppet.com/pe/latest/nc_groups.html#post-v1groupsid
    #
    # Updates `group` to ensure that it now contains `class_name` (or marks it
    # for deletion).  To commit changes, need to pass the updated
    # `group['class']` hash to `update_group`
    def self.ensure_class(group, class_name, delete:false)
      if group["classes"].has_key?(class_name) and delete
        # delete class by nilling its parameters
        group["classes"][class_name] = nil
        changes = true
      elsif ! group["classes"].has_key?(class_name) and ! delete
        # create class because we are not deleting it and it doesn't exist yet
        group["classes"][class_name] = {}
        changes = true
      else
        changes = false
      end

      changes
    end

    # Updates `group` to ensure that it now contains `param_name` set to
    # `param_value` (or marks the parameter it for deletion).  To commit changes
    # , need to pass the updated `group['class']` hash to `update_group`
    def self.ensure_param(group, class_name, param_name, param_value, delete:false)
      # ensure parameter set if specified
      if ! delete and (
            ! group["classes"][class_name].has_key?(param_name) or
            group["classes"][class_name][param_name] != param_value
          )
        # update or add a new parameter
        group["classes"][class_name][param_name] = param_value
        changes = true
      elsif delete and group["classes"][class_name].has_key?(param_name)
        group["classes"][class_name][param_name] = nil
        changes = true
      else
        changes = false
      end

      changes
    end

    # Updates `group` to ensure that it now contains classes and parameters as
    # specified in the `data` paramater.  To commit changes, need to pass the
    # updated `group['class']` hash to `update_group`
    def self.ensure_classes_and_params(group, data)
      updated = false
      if data
        data.each{ |class_name, params|
          Escort::Logger.output.puts "ensuring class: #{group['name']}->#{class_name}"
          updated |= ensure_class(group, class_name)
          if params
            params.each { |param_name, param_value|
              Escort::Logger.output.puts "ensuring param: #{group['name']}->#{class_name}->#{param_name}=#{param_value}"
              updated |= ensure_param(group, class_name, param_name, param_value)
            }
          end
        }
      end
      updated
    end

    # Ensure a particular rule exists in the group["rule"] array
    # This affects only the items in the chain, eg:
    # [
    #  "or",
    #   [
    #     <--- here!
    #   ]
    # ]
    #
    # Only the rule to be added in should be passed as the rule parameter, eg:
    # ["=", "name", "bob"]
    #
    # To commit changes, need to pass the updated `group['rule']` hash to `update_group`
    def self.ensure_rule(group, rule)
      updated = false

      # see if rule already exists, if it doesn't, append it
      found = false

      # rules are nested like this, the "or" applies to the whole rule chain:
      # "rule"=>["or", ["=", "name", "bob"], ["=", "name", "hello"]]
      group["rule"].drop(1).each {|system_rule|
        if  system_rule[0] == rule[0] and
            system_rule[1] == rule[1] and
            system_rule[2] == rule[2]
            # rule found
            found = true
        end
      }
      if ! found
        Escort::Logger.output.puts "Appending rule: #{rule}"
        group["rule"].push(rule)
        updated = true
      end

      updated
    end

    # Modify `group` to ensure the passed in `rules` exist. To commit changes,
    # need to pass the updated `group['rule']` hash to `update_group`
    #
    # rules need to arrive like this:
    # ["or", ["=", "name", "pupper.megacorp.com"], ["=", "name", "pupper.megacorp.com"]]
    # since the rule conjunction "or" can only be specified once per rule chain
    # we will replace whatever already exists in the rule with what the user
    # specified
    def self.ensure_rules(group, rules)
      updated = false

      if ! group["rule"] or group["rule"].empty?
        # no rules yet - just add our new one
        group["rule"] = [DEFAULT_RULE]
      end
      updated |= ensure_rule_conjunction(group, rules[0])
      rules.drop(1).each { |rule|
        updated |= ensure_rule(group, rule)
      }

      updated
    end

    # Ensure the correct boolean conjunction ('and'/'or' - 'not' is not allowed)
    # is being used for a given rule chain.  If user tried to append a rule with
    # a different conjuction to the one currently in use we will change the
    # conjuction used on the entire chain to match.
    #
    # Updates `group` in-place, To commit changes, need to pass the updated
    # `group['rule']` hash to `update_group`
    def self.ensure_rule_conjunction(group, op)
      updated = false
      if ["and", "or"].include?(op)
        if group["rule"][0] != op
          group["rule"][0] = op
          updated = true
        end
      else
        raise "Illegal rule conjunction #{op}, allowed: 'and', 'or'"
      end

      updated
    end

    # process any rule changes separately since they are valid for all actions
    # returns true if changes were made
    def self.rule_change(group, rule, rule_mode)
      rule_change = false

      rule_modes = ['replace', 'append']
      if rule and (! rule_modes.include?(rule_mode))
        raise "Invalid rule mode '#{rule_mode}'.  Allowed: #{rule_modes}"
      end

      if rule
        begin
          rule_json = JSON.parse(rule)
        rescue JSON::ParserError
          raise "Syntax error in data supplied to --rule (must be valid JSON)"
        end

        if rule_mode == 'replace'
          if group['rule'] != rule_json
            group['rule'] = rule_json
            rule_change = true
          end
        else
          rule_change = ensure_rules(group, rule_json)
        end
      end

      rule_change
    end

    def self.classes(options)
      group_name    = options[:group_name]
      class_name    = options[:class_name]
      param_name    = options[:param_name]
      param_value   = options[:param_value]
      delete_class  = options[:delete_class]
      delete_param  = options[:delete_param]
      rule          = options[:rule]
      rule_mode     = options[:rule_mode]
      smart_update  = options[:smart_update]

      rule_change   = false
      class_change  = false

      if group_name
        group = nc_group(group_name)
      else
        raise "All operations require a valid group_name"
      end

      if class_name and delete_class
        # delete a class from a group
        Escort::Logger.output.puts "Deleting class #{class_name} from #{group_name}"
        class_change = ensure_class(group, class_name, delete:true)
      elsif class_name and param_name and delete_param
        # delete a parameter from a class
        Escort::Logger.output.puts "Deleting parameter #{param_name} on #{class_name} from #{group_name}"
        class_change = ensure_class(group, class_name)
        class_change |= ensure_param(group, class_name, param_name, nil, delete:true)
      elsif class_name and param_name and param_value
        # set a value inside a class
        if smart_update
          if ! is_r10k_param(class_name, param_name)

            # not an R10K parameter, do an immediate update to make sure any classes
            # we need are in-place
            puppet_code_deploy
          end
        end
        Escort::Logger.output.puts "Setting parameter #{param_name} to #{param_value} on #{class_name} in #{group_name}"
        class_change = ensure_class(group, class_name)
        class_change |= ensure_param(group, class_name, param_name, param_value)
      elsif class_name
        if smart_update
          puppet_code_deploy
        end
        Escort::Logger.output.puts "Adding #{class_name} to #{group_name}"
        class_change = ensure_class(group, class_name)
      end

      # process any rule changes separately since they are valid for all actions
      rule_change = rule_change(group, rule, rule_mode)

      # save changes
      if class_change or rule_change
        update_group(group_name, classes: group["classes"], rule: group["rule"])
      else
        Escort::Logger.output.puts "Already up-to-date"
      end
    end

    def self.update_classes
      if ! @puppetclassify
        init
      end
      @puppet_https.delete("#{@puppet_url}/puppet-admin-api/v1/environment-cache")
      @puppet_https.post("#{@rest_api_url}/v1/update-classes")
    end

    def self.puppet_code_deploy
      Escort::Logger.output.puts "Running puppet and deploying code..."

      # if puppet run fails, just deploy the code anyway as the fix needed might
      # be in the update...
      system("puppet agent -t ; puppet-code deploy --all --wait")
    end

    # Extract the r10k settings ONLY from the passed in data has and update
    # NCAPI with them immediately
    def self.apply_r10k_settings_now(data)
      data.each { |group_name,opts|
        group = nc_group(group_name)

        if opts.key?("classes")
          Escort::Logger.output.puts "Setting up rules for #{group_name} immediately"
          if ensure_classes_and_params(group, opts["classes"])
            update_group(group_name, classes: group["classes"])
          end
        end
      }
    end

    # Check if this is an r10k parameter or not
    #
    # @return true if this is to do with R10K otherwise false
    def self.is_r10k_param(class_name, param_name)
      class_name == R10K_SETTINGS_CLASS and R10K_SETTINGS_PARAMS.include?(param_name)
    end

    # Evaluate whether change instructions contain R10K settings or not
    #
    # @param data Hash of data settings to look at
    # @return false if not found otherwise hash of with just the settings that
    #   need to be applied immediately
    def self.contains_r10k_settings(data)
      found = {}
      data.each { |group_name, opts|
        if opts.key?("classes") and opts["classes"].key?(R10K_SETTINGS_CLASS)
          opts["classes"][R10K_SETTINGS_CLASS].each { |param_name,param_value|
            if is_r10k_param(R10K_SETTINGS_CLASS, param_name)
              # make the hash structure we need
              if ! found.key?(group_name)
                found[group_name] = {}
              end

              if ! found[group_name].key?("classes")
                found[group_name]["classes"] = {}
              end

              if ! found[group_name]["classes"].key?(R10K_SETTINGS_CLASS)
                found[group_name]["classes"][R10K_SETTINGS_CLASS] = {}
              end

              found[group_name]["classes"][R10K_SETTINGS_CLASS][param_name] = param_value
            end
          }
        end
      }

      # Return the found elements if there were any, otherwise simplify to false
      ! found.empty? ? found : false
    end

    def self.groups(options)
      group_name          = options[:group_name]
      environment         = options[:environment]
      environment_trumps  = options[:environment_trumps]
      rule                = options[:rule]
      rule_mode           = options[:rule_mode]

      # step 1: create the group with the parent "All Environments"
      nc_group(group_name, parent_name: "All Environments")

      # step 2: set the environment + environment trumps
      update_group(
        group_name,
        environment: environment,
        environment_trumps: environment_trumps,
      )

      # step 3: set the rules - separate step because rule_mode needs special
      # handling
      group = nc_group(group_name)
      rule_change = rule_change(group, rule, rule_mode)
      if rule_change
        update_group(group_name, rule: group["rule"])
      end
    end
  end
end
