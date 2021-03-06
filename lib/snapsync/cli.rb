require 'thor'
require 'snapsync'

module Snapsync
    class CLI < Thor
        class_option :debug, type: :boolean, default: false

        no_commands do
            def config_from_name(name)
                path = Pathname.new(name)
                if !path.exist?
                    path = SnapperConfig.default_config_dir + path
                    if !path.exist?
                        raise ArgumentError, "cannot find any snapper configuration called #{name}"
                    end
                end
                SnapperConfig.load(path)
            end

            def handle_class_options
                if options[:debug]
                    Snapsync.logger.level = 'DEBUG'
                end
            end

            # Resolves a path (or nil) into a list of snapsync targets and
            # yields them
            #
            # @param [String,nil] dir the path the user gave, or nil if all
            #   available auto-sync paths should be processed. If the directory is
            #   a target, it is yield as-is. It can also be the root of a sync-all
            #   target (with proper snapsync target as subdirectories whose name
            #   matches the snapper configurations)
            #
            # @yieldparam [LocalTarget] target
            def each_target(dir = nil)
                return enum_for(__method__) if !block_given?
                if dir
                    dir = Pathname.new(dir)
                    begin
                        return yield(LocalTarget.new(dir, create_if_needed: false))
                    rescue LocalTarget::InvalidTargetPath
                    end

                    SyncAll.new(dir).each_target do |config, target|
                        yield(config, target)
                    end
                else
                    autosync = AutoSync.load_default
                    autosync.each_available_target do |config, target|
                        yield(config, target)
                    end
                end
            end
        end

        desc 'sync CONFIG DIR', 'synchronizes the snapper configuration CONFIG with the snapsync target DIR'
        option :autoclean, type: :boolean, default: nil,
            desc: 'whether the target should be cleaned of obsolete snapshots',
            long_desc: "The default is to use the value specified in the target's configuration file. This command line option allows to override the default"
        def sync(config_name, dir)
            handle_class_options

            config = config_from_name(config_name)
            target = LocalTarget.new(Pathname.new(dir))
            Sync.new(config, target, autoclean: options[:autoclean]).run
        end

        desc 'sync-all DIR', 'synchronizes all snapper configurations into corresponding subdirectories of DIR'
        option :autoclean, type: :boolean, default: nil,
            desc: 'whether the target should be cleaned of obsolete snapshots',
            long_desc: "The default is to use the value specified in the target's configuration file. This command line option allows to override the default"
        def sync_all(dir)
            handle_class_options

            dir = Pathname.new(dir)
            op = SyncAll.new(dir, config_dir: SnapperConfig.default_config_dir, autoclean: options[:autoclean])
            op.run
        end

        desc 'cleanup CONFIG DIR', 'cleans up the snapsync target DIR based on the policy set by the policy command'
        option :dry_run, type: :boolean, default: false
        def cleanup(dir)
            handle_class_options

            target = LocalTarget.new(Pathname.new(dir))
            if target.cleanup
                target.cleanup.cleanup(target, dry_run: options[:dry_run])
            else
                Snapsync.info "#{target.sync_policy.class.name} policy set, nothing to do"
            end
        end

        desc 'init NAME DIR [POLICY]', 'creates a synchronization target, optionally specifying the synchronization and cleanup policy'
        long_desc <<-EOD
By default, the default policy is used. To change this, provide additional
arguments as would be expected by the policy subcommand. Run snapsync help
policy for more information
        EOD
        option :all, type: :boolean, default: true,
            desc: "if true (the default), create one snapsync target per snapper configuration under DIR, otherwise, initialize only one target directly in DIR"
        option :auto, type: :boolean, default: true,
            desc: "if true (the default), add the newly created target to auto-sync"
        option :automount, type: :boolean, default: true,
            desc: 'whether the supporting partition should be auto-mounted by snapsync when needed or not (the default is yes). Only useful if --no-auto has not been provided on the command line.'
        def init(name, dir, *policy)
            dir = Pathname.new(dir)

            if policy.empty?
                policy = ['default', Array.new]
            elsif policy.size == 1
                policy << Array.new
            end

            dirs = Array.new
            if options[:all]
                SnapperConfig.each_in_dir do |config|
                    dirs << dir + config.name
                end
            else
                dirs << dir
            end

            dirs.each do |path|
                begin
                    LocalTarget.new(path, create_if_needed: false)
                    Snapsync.info "#{path} was already initialized"
                rescue ArgumentError, LocalTarget::NoUUIDError
                    path.mkpath
                    target = LocalTarget.new(path)
                    target.change_policy(*policy)
                    target.write_config
                    Snapsync.info "initialized #{path} as a snapsync target"
                end
            end

            if options[:auto]
                if !options[:all]
                    Snapsync.warn "cannot use --auto without --all"
                else
                    auto_add(name, dir)
                end
            end
        end

        desc 'auto-add NAME DIR', "add DIR to the set of targets for auto-sync"
        option :automount, type: :boolean, default: true,
            desc: 'whether the supporting partition should be auto-mounted by snapsync when needed or not (the default is yes)'
        def auto_add(name, dir)
            partitions = PartitionsMonitor.new
            uuid, relative = partitions.partition_of(Pathname.new(dir))

            conf_path = Pathname.new('/etc/snapsync.conf')

            autosync = AutoSync.new
            autosync.load_config(conf_path)
            exists = autosync.each_autosync_target.find do |t|
                t.partition_uuid == uuid && t.path.cleanpath == relative.cleanpath
            end
            if exists
                if exists.automount == options[:automount]
                    Snapsync.info "already exists under the name #{exists.name}"
                else
                    Snapsync.info "already exists under the name #{exists.name} but with a different automount flag, changing"
                    exists.automount = options[:automount]
                end
                exists.name ||= name
            else
                autosync.add AutoSync::AutoSyncTarget.new(uuid, relative, options[:automount], name)
            end
            autosync.write_config(conf_path)
        end

        desc 'auto-remove NAME', "remove a target from auto-sync by name"
        def auto_remove(name)
            conf_path = Pathname.new('/etc/snapsync.conf')
            autosync = AutoSync.new
            autosync.load_config(conf_path)
            autosync.remove(name: name)
            autosync.write_config(conf_path)
        end

        desc 'policy DIR TYPE [OPTIONS]', 'sets the synchronization and cleanup policy for the given target or targets'
        long_desc <<-EOD
This command sets the policy used to decide which snapshots to synchronize to
the target, and which to not synchronize.

Three policy types can be used: default, last and timeline

The default policy takes no argument. It will synchronize all snapshots present in the source, and do no cleanup

The last policy takes no argument. It will synchronize (and keep) only the last snapshot

The timeline policy takes periods of time as argument (as e.g. day 10 or month 20). It will keep at least
one snapshot for each period, and for the duration specified (day 10 tells to keep one snapshot per day
for 10 days). snapsync understands the following period names: year month day hour.
        EOD
        def policy(dir, type, *options)
            handle_class_options
            each_target(dir) do |_, target|
                target.change_policy(type, options)
                target.write_config
            end
        end

        desc 'destroy DIR', 'destroys a snapsync target'
        long_desc <<-EOD
While it can easily be done manually, this command makes sure that the snapshots are properly deleted
        EOD
        def destroy(dir)
            handle_class_options
            target_dir = Pathname.new(dir)
            target = LocalTarget.new(target_dir, create_if_needed: false)
            snapshots = target.each_snapshot.to_a
            snapshots.sort_by(&:num).each do |s|
                target.delete(s)
            end
            target_dir.rmtree
        end

        desc "auto-sync", "automatic synchronization"
        option :config_file, desc: "path to the config file (defaults to /etc/snapsync.conf)",
            default: '/etc/snapsync.conf'
        def auto_sync
            handle_class_options
            auto = AutoSync.new(SnapperConfig.default_config_dir)
            auto.load_config(Pathname.new(options[:config_file]))
            auto.run
        end

        desc 'list [DIR]', 'list the snapshots present on DIR. If DIR is omitted, tries to access all targets defined as auto-sync targets'
        def list(dir = nil)
            handle_class_options
            each_target(dir) do |_, target|
                puts "== #{target.dir}"
                puts "UUID: #{target.uuid}"
                puts "Enabled: #{target.enabled?}"
                puts "Autoclean: #{target.autoclean?}"
                print "Policy: "
                pp target.sync_policy

                puts "Snapshots:"
                target.each_snapshot do |s|
                    puts "  #{s.num} #{s.to_time}"
                end
            end
        end
    end
end

