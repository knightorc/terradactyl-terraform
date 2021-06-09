# frozen_string_literal: true

module Terradactyl
  module Terraform
    class << self
      def calc_revision(version)
        major, minor = version.split(/\.|-/).take(2)
        major = major.to_i.zero? ? major : major + '_'
        minor = minor.rjust(2, '0') # pad a single digit
        ['Rev', major, minor].join
      end

      def revision(version)
        version ? calc_revision(version) : revisions.last
      end

      def revisions
        constants.select { |c| c =~ /Rev/ }.sort
      end

      def select_revision(version, object)
        klass_name = object.class.name.split('::').last
        revision   = "#{revision(version)}::#{klass_name}"
        return if klass_name == 'Base'

        if Terradactyl::Terraform.const_defined?(revision)
          object.extend(Terradactyl::Terraform.const_get(revision))
        else
          object.extend(Terradactyl::Terraform.const_get("Subcommands::#{klass_name}"))
        end
      end
    end

    module Commands
      class Base
        def self.execute(dir_or_plan: nil, options: nil, capture: false)
          new(dir_or_plan: dir_or_plan,
              options: options).execute(capture: capture)
        end

        attr_accessor :dir_or_plan, :options

        def initialize(dir_or_plan: nil, options: nil)
          @dir_or_plan = dir_or_plan.to_s
          @options     = options || Options.new
          Terradactyl::Terraform.select_revision(version, self)
          inject_env_vars
        end

        def execute(capture: false)
          cmd = assemble_command
          echo_cmd(cmd)
          send((capture ? :capture3 : :popen3), ENV, cmd)
        end

        private

        def capture3(env, cmd)
          results = %w[stdout stderr status].zip(Open3.capture3(env, *cmd))
          OpenStruct.new(Hash[results]).tap do |dat|
            dat.exitstatus = dat.status.exitstatus
          end
        end

        def popen3(env, cmd)
          Open3.popen3(env, *cmd) do |stdin, stdout, stderr, wait_thru|
            stdin.close
            print_stdout($LAST_READ_LINE) while stdout.gets
            print_stderr($LAST_READ_LINE) while stderr.gets
            wait_thru.value.exitstatus
          end
        end

        def binary
          VersionManager.binary
        end

        def version
          File.basename(VersionManager.binary, '.exe').split('terraform-').last
        end

        def environment
          options.environment.to_h
        end

        def echo
          options.echo
        end

        def quiet
          options.quiet
        end

        def arguments
          options.to_h
                 .reject { |k, _v| options.defaults.key?(k) }
                 .transform_keys { |k| k.to_s.gsub('_', '-') }
        end

        def defaults
          {}
        end

        def switches
          []
        end

        def expandable_path_vars
          %w[
            TF_CLI_CONFIG_FILE
            TF_LOG_PATH
            TF_PLUGIN_CACHE_DIR
          ]
        end

        def tf_data_dir
          dir = Dir.exist?(dir_or_plan) ? dir_or_plan : File.dirname(dir_or_plan)
          File.expand_path(File.join(dir, '.terraform'))
        end

        def expand_existing_env_vars
          expandable_path_vars.each do |var|
            ENV[var] = File.expand_path(ENV[var]) unless ENV[var].nil?
          end
        end

        def inject_env_vars
          ENV['TF_DATA_DIR'] = tf_data_dir
          environment.each { |k, v| ENV[k.to_s] = v }
          expand_existing_env_vars
        end

        def echo_cmd(cmd)
          puts "Executing: #{cmd}" if echo
        end

        def print_stdout(msg)
          return unless msg

          puts msg unless quiet
        end

        def print_stderr(msg)
          return unless msg

          puts msg
        end

        def compile_arguments
          [defaults, arguments].inject({}) { |memo, hash| memo.merge!(hash) }
                               .reject { |k, v| defaults[k] == v }
        end

        def validate_arguments
          compiled = compile_arguments
          if (invalid = compiled.keys - (compiled.keys & defaults.keys)).any?
            raise "Invalid arguments: #{invalid}"
          end

          compiled
        end

        def assemble_command
          args = validate_arguments.each_with_object([]) do |(k, v), memo|
            memo << (switches.member?(k) ? "-#{k}" : "-#{k}=#{v}")
          end
          [binary, subcmd, args, dir_or_plan].flatten
                                             .compact
                                             .map(&:to_s)
                                             .reject(&:empty?)
        end

        def subcmd
          sig = self.class.name.split('::').last.downcase
          sig == 'base' ? '' : sig
        end
      end
    end
  end
end
