require "vmc/cli"
require "vmc/detect"

module VMC
  class App < CLI
    MEM_CHOICES = ["64M", "128M", "256M", "512M"]

    # TODO: don't hardcode; bring in from remote
    MEM_DEFAULTS_FRAMEWORK = {
      "rails3" => "256M",
      "spring" => "512M",
      "grails" => "512M",
      "lift" => "512M",
      "java_web" => "512M",
      "standalone" => "64M",
      "sinatra" => "128M",
      "node" => "64M",
      "php" => "128M",
      "otp_rebar" => "64M",
      "wsgi" => "64M",
      "django" => "128M",
      "dotNet" => "128M",
      "rack" => "128M",
      "play" => "256M"
    }

    MEM_DEFAULTS_RUNTIME = {
      "java7" => "512M",
      "java" => "512M",
      "php" => "128M",
      "ruby" => "128M",
      "ruby19" => "128M"
    }


    desc "List your applications"
    group :apps
    input :name, :desc => "Filter by name regexp"
    input :runtime, :desc => "Filter by runtime regexp"
    input :framework, :desc => "Filter by framework regexp"
    input :url, :desc => "Filter by url regexp"
    def apps(input)
      apps =
        with_progress("Getting applications") do
          client.apps
        end

      if apps.empty? and !simple_output?
        puts ""
        puts "No applications."
        return
      end

      apps.each.with_index do |a, num|
        display_app(a) if app_matches(a, input)
      end
    end


    desc "Push an application, syncing changes if it exists"
    group :apps, :manage
    input(:name, :argument => true) { ask("Name") }
    input(:path)
    input(:url) { |default|
      ask("URL", :default => default)
    }
    input(:memory) { |framework, runtime|
      ask("Memory Limit",
          :choices => MEM_CHOICES,
          :default =>
            MEM_DEFAULTS_RUNTIME[runtime] ||
              MEM_DEFAULTS_FRAMEWORK[framework] ||
              "64M")
    }
    input(:instances, :type => :integer) {
      ask("Instances", :default => 1)
    }
    input(:framework) { |choices, default|
      opts = {:choices => choices}
      opts[:default] = default if default

      ask("Framework", opts)
    }
    input(:runtime) { |choices|
      ask("Runtime", :choices => choices)
    }
    input(:command) {
      ask("Startup command")
    }
    input(:start, :type => :boolean, :default => true)
    input(:restart, :type => :boolean, :default => true)
    input(:create_services, :type => :boolean) {
      ask "Create services for application?", :default => false
    }
    input(:bind_services, :type => :boolean) {
      ask "Bind other services to application?", :default => false
    }
    def push(input)
      path = File.expand_path(input[:path] || ".")

      name = input[:name] if input[:name]

      detector = Detector.new(client, path)
      frameworks = detector.all_frameworks
      detected, default = detector.frameworks

      app = client.app(name)

      if app.exists?
        upload_app(app, path)
        invoke :restart, :name => app.name if input[:restart]
        return
      end

      app.total_instances = input[:instances]

      if detected.empty?
        framework = input[:framework, frameworks.keys.sort, nil]
      else
        framework = input[:framework, detected.keys.sort + ["other"], default]
        if framework == "other"
          input.forget(:framework)
          framework = input[:framework, frameworks.keys.sort, nil]
        end
      end

      framework_runtimes =
        frameworks[framework]["runtimes"].collect { |k| k["name"] }

      runtime = input[:runtime, framework_runtimes.sort]

      app.framework = framework
      app.runtime = runtime

      if framework == "standalone"
        app.command = input[:command]

        if (url = input[:url, "none"]) != "none"
          app.urls = [url]
        else
          app.urls = []
        end
      else
        domain = client.target.sub(/^https?:\/\/api\.(.+)\/?/, '\1')
        app.urls = [input[:url, "#{name}.#{domain}"]]
      end

      app.memory = megabytes(input[:memory, framework, runtime])

      bindings = []
      if input[:create_services] && !force?
        services = client.system_services

        while true
          vendor = ask "What kind?", :choices => services.keys.sort
          meta = services[vendor]

          if meta[:versions].size == 1
            version = meta[:versions].first
          else
            version = ask "Which version?",
              :choices => meta[:versions].sort.reverse
          end

          random = sprintf("%x", rand(1000000))
          service_name = ask "Service name?", :default => "#{vendor}-#{random}"

          service = client.service(service_name)
          service.type = meta[:type]
          service.vendor = meta[:vendor]
          service.version = version
          service.tier = "free"

          with_progress("Creating service #{c(service_name, :name)}") do
            service.create!
          end

          bindings << service_name

          break unless ask "Create another service?", :default => false
        end
      end

      if input[:bind_services] && !force?
        services = client.services.collect(&:name)

        while true
          choices = services - bindings
          break if choices.empty?

          bindings << ask("Bind which service?", :choices => choices.sort)

          unless bindings.size < services.size &&
                  ask("Bind another service?", :default => false)
            break
          end
        end
      end

      app.services = bindings

      app = filter(:push_app, app)

      with_progress("Creating #{c(name, :name)}") do
        app.create!
      end

      begin
        upload_app(app, path)
      rescue
        err "Upload failed. Try again with 'vmc push'."
        raise
      end

      invoke :start, :name => app.name if input[:start]
    end


    desc "Start an application"
    group :apps, :manage
    input :names, :argument => :splat, :singular => :name
    input :debug_mode, :aliases => "-d"
    def start(input)
      names = input[:names]
      fail "No applications given." if names.empty?

      names.each do |name|
        app = client.app(name)

        fail "Unknown application '#{name}'" unless app.exists?

        app = filter(:start_app, app)

        switch_mode(app, input[:debug_mode])

        with_progress("Starting #{c(name, :name)}") do |s|
          if app.started?
            s.skip do
              err "Already started."
            end
          end

          app.start!
        end

        check_application(app)

        if app.debug_mode && !simple_output?
          puts ""
          instances(name)
        end
      end
    end


    desc "Stop an application"
    group :apps, :manage
    input :names, :argument => :splat, :singular => :name
    def stop(input)
      names = input[:names]
      fail "No applications given." if names.empty?

      names.each do |name|
        with_progress("Stopping #{c(name, :name)}") do |s|
          app = client.app(name)

          unless app.exists?
            s.fail do
              err "Unknown application '#{name}'"
            end
          end

          if app.stopped?
            s.skip do
              err "Application is not running."
            end
          end

          app.stop!
        end
      end
    end


    desc "Stop and start an application"
    group :apps, :manage
    input :names, :argument => :splat, :singular => :name
    input :debug_mode, :aliases => "-d"
    def restart(input)
      invoke :stop, :names => input[:names]
      invoke :start, :names => input[:names]
    end


    desc "Delete an application"
    group :apps, :manage
    input :name
    input(:really, :type => :boolean) { |name, color|
      force? || ask("Really delete #{c(name, color)}?", :default => false)
    }
    input(:names, :argument => :splat, :singular => :name) { |names|
      [ask("Delete which application?", :choices => names)]
    }
    input(:orphaned, :aliases => "-o", :type => :boolean,
          :desc => "Delete orphaned instances")
    input(:all, :default => false)
    def delete(input)
      if input[:all]
        return unless input[:really, "ALL APPS", :bad]

        apps = client.apps

        orphaned = find_orphaned_services(apps)

        apps.each do |a|
          with_progress("Deleting #{c(a.name, :name)}") do
            a.delete!
          end
        end

        delete_orphaned_services(orphaned, input[:orphaned])

        return
      end

      apps = client.apps
      fail "No applications." if apps.empty?

      names = input[:names, apps.collect(&:name).sort]

      to_delete = names.collect do |n|
        if app = apps.find { |a| a.name == n }
          app
        else
          fail "Unknown application '#{n}'"
        end
      end

      deleted = []
      to_delete.each do |app|
        really = input[:really, app.name, :name]
        next unless really

        deleted << app

        with_progress("Deleting #{c(app.name, :name)}") do
          app.delete!
        end
      end

      unless deleted.empty?
        delete_orphaned_services(
          find_orphaned_services(deleted),
          input[:orphaned])
      end
    end


    desc "List an app's instances"
    group :apps, :info, :hidden => true
    input :names, :argument => :splat, :singular => :name
    def instances(input)
      names = input[:names]
      fail "No applications given." if names.empty?

      names.each do |name|
        instances =
          with_progress("Getting instances for #{c(name, :name)}") do
            client.app(name).instances
          end

        instances.each do |i|
          if simple_output?
            puts i.index
          else
            puts ""
            display_instance(i)
          end
        end
      end
    end


    desc "Update the instances/memory limit for an application"
    group :apps, :info, :hidden => true
    input :name, :argument => true
    input(:instances, :type => :numeric) { |default|
      ask("Instances", :default => default)
    }
    input(:memory) { |default|
      ask("Memory Limit", :choices => MEM_CHOICES,
          :default => human_size(default * 1024 * 1024, 0))
    }
    input :restart, :default => true
    def scale(input)
      name = input[:name]
      app = client.app(name)

      instances = input.given(:instances)
      memory = input.given(:memory)

      unless instances || memory
        instances = input[:instances, app.total_instances]
        memory = input[:memory, app.memory]
      end

      megs = megabytes(memory)

      memory_changed = megs != app.memory
      instances_changed = instances != app.total_instances

      return unless memory_changed || instances_changed

      with_progress("Scaling #{c(name, :name)}") do
        app.total_instances = instances.to_i if instances
        app.memory = megs if memory
        app.update!
      end

      if memory_changed && app.started? && input[:restart]
        invoke :restart, :name => name
      end
    end


    desc "Print out an app's logs"
    group :apps, :info, :hidden => true
    input :name, :argument => true
    input(:instance, :type => :numeric, :default => 0)
    input(:all, :default => false)
    def logs(input)
      name = input[:name]

      app = client.app(name)
      fail "Unknown application '#{name}'" unless app.exists?

      instances =
        if input[:all]
          app.instances
        else
          app.instances.select { |i| i.index == input[:instance] }
        end

      if instances.empty?
        if input[:all]
          fail "No instances found."
        else
          fail "Instance #{name} \##{input[:instance]} not found."
        end
      end

      instances.each do |i|
        logs =
          with_progress(
            "Getting logs for " +
              c(name, :name) + " " +
              c("\##{i.index}", :instance)) do
            i.files("logs")
          end

        puts "" unless simple_output?

        logs.each do |log|
          body =
            with_progress("Reading " + b(log.join("/"))) do
              i.file(*log)
            end

          puts body
          puts "" unless body.empty?
        end
      end
    end


    desc "Print out an app's file contents"
    group :apps, :info, :hidden => true
    input :name, :argument => true
    input :path, :argument => true, :default => "/"
    def file(input)
      file =
        with_progress("Getting file contents") do
          client.app(input[:name]).file(*input[:path].split("/"))
        end

      puts "" unless simple_output?

      print file
    end

    desc "Examine an app's files"
    group :apps, :info, :hidden => true
    input :name, :argument => true
    input :path, :argument => true, :default => "/"
    def files(input)
      files =
        with_progress("Getting file listing") do
          client.app(input[:name]).files(*input[:path].split("/"))
        end

      puts "" unless simple_output?
      files.each do |file|
        puts file.join("/")
      end
    end


    desc "Get application health"
    group :apps, :info, :hidden => true
    input :names, :argument => :splat, :singular => :name
    def health(input)
      apps =
        with_progress("Getting application health") do
          input[:names].collect do |n|
            [n, app_status(client.app(n))]
          end
        end

      apps.each do |name, status|
        unless quiet?
          puts ""
          print "#{c(name, :name)}: "
        end

        puts status
      end
    end


    desc "Display application instance status"
    group :apps, :info, :hidden => true
    input :name, :argument => true
    def stats(input)
      stats =
        with_progress("Getting stats for #{c(input[:name], :name)}") do
          client.app(input[:name]).stats
        end

      stats.sort_by { |k, _| k }.each do |idx, info|
        puts ""

        if info["state"] == "DOWN"
          puts "Instance #{c("\##{idx}", :instance)} is down."
          next
        end

        stats = info["stats"]
        usage = stats["usage"]
        puts "instance #{c("\##{idx}", :instance)}:"
        print "  cpu: #{percentage(usage["cpu"])} of"
        puts " #{b(stats["cores"])} cores"
        puts "  memory: #{usage(usage["mem"] * 1024, stats["mem_quota"])}"
        puts "  disk: #{usage(usage["disk"], stats["disk_quota"])}"
      end
    end


    desc "Add a URL mapping for an app"
    group :apps, :info, :hidden => true
    input :name, :argument => true
    input :url, :argument => true
    def map(input)
      name = input[:name]
      simple = input[:url].sub(/^https?:\/\/(.*)\/?/i, '\1')

      with_progress("Updating #{c(name, :name)}") do
        app = client.app(name)
        app.urls << simple
        app.update!
      end
    end


    desc "Remove a URL mapping from an app"
    group :apps, :info, :hidden => true
    input :name, :argument => true
    input(:url, :argument => true) { |choices|
      ask("Which URL?", :choices => choices)
    }
    def unmap(input)
      name = input[:name]
      app = client.app(name)

      url = input[:url, app.urls]

      simple = url.sub(/^https?:\/\/(.*)\/?/i, '\1')

      fail "Unknown application '#{name}'" unless app.exists?

      with_progress("Updating #{c(name, :name)}") do |s|
        unless app.urls.delete(simple)
          s.fail do
            err "URL #{url} is not mapped to this application."
            return
          end
        end

        app.update!
      end
    end


    desc "Show all environment variables set for an app"
    group :apps, :info, :hidden => true
    input :name, :argument => true
    def env(input)
      appname = input[:name]

      vars =
        with_progress("Getting env for #{c(input[:name], :name)}") do |s|
          app = client.app(appname)

          unless app.exists?
            s.fail do
              err "Unknown application '#{appname}'"
              return
            end
          end

          app.env
        end

      puts "" unless simple_output?

      vars.each do |pair|
        name, val = pair.split("=", 2)
        puts "#{c(name, :name)}: #{val}"
      end
    end


    VALID_ENV_VAR = /^[a-zA-Za-z_][[:alnum:]_]*$/

    desc "Set an environment variable"
    group :apps, :info, :hidden => true
    input :name, :argument => true
    input :var, :argument => true
    input :value, :argument => :optional
    input :restart, :default => true
    def env_add(input)
      appname = input[:name]
      name = input[:var]

      if value = input[:value]
        name = input[:var]
      elsif name["="]
        name, value = name.split("=")
      end

      unless name =~ VALID_ENV_VAR
        fail "Invalid variable name; must match #{VALID_ENV_VAR.inspect}"
      end

      app = client.app(appname)
      fail "Unknown application '#{appname}'" unless app.exists?

      with_progress("Updating #{c(app.name, :name)}") do
        app.update!("env" =>
                      app.env.reject { |v|
                        v.start_with?("#{name}=")
                      }.push("#{name}=#{value}"))
      end

      if app.started? && input[:restart]
        invoke :restart, :name => app.name
      end
    end

    alias_command :env_add, :env_set
    alias_command :env_add, :set_env
    alias_command :env_add, :add_env


    desc "Remove an environment variable"
    group :apps, :info, :hidden => true
    input :restart, :default => true
    input :name, :argument => true
    input :var, :argument => true
    def env_del(input)
      appname = input[:name]
      name = input[:var]

      app = client.app(appname)
      fail "Unknown application '#{appname}'" unless app.exists?

      with_progress("Updating #{c(app.name, :name)}") do
        app.update!("env" =>
                      app.env.reject { |v|
                        v.start_with?("#{name}=")
                      })
      end

      if app.started? && input[:restart]
        invoke :restart, :name => app.name
      end
    end

    alias_command :env_del, :delete_env


    desc "DEPRECATED. Use 'push' instead."
    def update(input)
      fail "The 'update' command is no longer needed; use 'push' instead."
    end

    private

    def app_matches(a, options)
      if name = options[:name]
        return false if a.name !~ /#{name}/
      end

      if runtime = options[:runtime]
        return false if a.runtime !~ /#{runtime}/
      end

      if framework = options[:framework]
        return false if a.framework !~ /#{framework}/
      end

      if url = options[:url]
        return false if a.urls.none? { |u| u =~ /#{url}/ }
      end

      true
    end

    IS_UTF8 = !!(ENV["LC_ALL"] || ENV["LC_CTYPE"] || ENV["LANG"])["UTF-8"]

    def display_app(a)
      if simple_output?
        puts a.name
        return
      end

      puts ""

      status = app_status(a)

      puts "#{c(a.name, :name)}: #{status}"

      puts "  platform: #{b(a.framework)} on #{b(a.runtime)}"

      print "  usage: #{b(human_size(a.memory * 1024 * 1024, 0))}"
      print " #{c(IS_UTF8 ? "\xc3\x97" : "x", :dim)} #{b(a.total_instances)}"
      print " instance#{a.total_instances == 1 ? "" : "s"}"
      puts ""

      unless a.urls.empty?
        puts "  urls: #{a.urls.collect { |u| b(u) }.join(", ")}"
      end

      unless a.services.empty?
        puts "  services: #{a.services.collect { |s| b(s) }.join(", ")}"
      end
    end

    def upload_app(app, path)
      with_progress("Uploading #{c(app.name, :name)}") do
        app.upload(path)
      end
    end

    # set app debug mode, ensuring it's valid, and shutting it down
    def switch_mode(app, mode)
      mode = nil if mode == "none"
      mode = "run" if mode == "debug_mode" # no value given

      return false if app.debug_mode == mode

      if mode.nil?
        with_progress("Removing debug mode") do
          app.debug_mode = nil
          app.stop! if app.started?
        end

        return true
      end

      with_progress("Switching mode to #{c(mode, :name)}") do |s|
        runtimes = client.system_runtimes
        modes = runtimes[app.runtime]["debug_modes"] || []
        if modes.include?(mode)
          app.debug_mode = mode
          app.stop! if app.started?
        else
          fail "Unknown mode '#{mode}'; available: #{modes.join ", "}"
        end
      end
    end

    APP_CHECK_LIMIT = 60

    def check_application(app)
      with_progress("Checking #{c(app.name, :name)}") do |s|
        if app.debug_mode == "suspend"
          s.skip do
            puts "Application is in suspended debugging mode."
            puts "It will wait for you to attach to it before starting."
          end
        end

        seconds = 0
        until app.healthy?
          sleep 1
          seconds += 1
          if seconds == APP_CHECK_LIMIT
            s.give_up do
              err "Application failed to start."
              # TODO: print logs
            end
          end
        end
      end
    end

    # choose the right color for app/instance state
    def state_color(s)
      case s
      when "STARTING"
        :neutral
      when "STARTED", "RUNNING"
        :good
      when "DOWN"
        :bad
      when "FLAPPING"
        :error
      when "N/A"
        :unknown
      else
        :warning
      end
    end

    def app_status(a)
      health = a.health

      if a.debug_mode == "suspend" && health == "0%"
        c("suspended", :neutral)
      else
        c(health.downcase, state_color(health))
      end
    end

    def display_instance(i)
      print "instance #{c("\##{i.index}", :instance)}: "
      puts "#{b(c(i.state.downcase, state_color(i.state)))} "

      puts "  started: #{c(i.since.strftime("%F %r"), :cyan)}"

      if d = i.debugger
        puts "  debugger: port #{b(d[:port])} at #{b(d[:ip])}"
      end

      if c = i.console
        puts "  console: port #{b(c[:port])} at #{b(c[:ip])}"
      end
    end

    def find_orphaned_services(apps)
      orphaned = []

      apps.each do |a|
        a.services.each do |s|
          if apps.none? { |x| x != a && x.services.include?(s) }
            orphaned << s
          end
        end
      end

      orphaned
    end

    def delete_orphaned_services(names, orphaned)
      return if names.empty?

      puts "" unless simple_output?

      names.select { |s|
        orphaned ||
          ask("Delete orphaned service #{c(s, :name)}?", :default => false)
      }.each do |s|
        with_progress("Deleting service #{c(s, :name)}") do
          client.service(s).delete!
        end
      end
    end
  end
end
