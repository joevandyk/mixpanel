require "open-uri"
require 'base64'
require 'json'
require 'thread'
require 'mixpanel/tracker/middleware'

module Mixpanel
  class Tracker
    # Instead of defaulting @async_option to false, it should
    # default to a module/class that represents sending the
    # request to mixpanel syncronously.
    # For backwards compatability, if true passed in, then
    # @async_option could be the class that wrapped the Worker logic.
    #
    # A sample module:
    # module App::MixpanelAsync
    #   def self.perform url
    #     Resque.enqueue(queue, url)
    #   end
    #  end
    #
    #  mixpanel = Mixpanel::Tracker.new(api_key, request.env, App::MixpanelAsync
    #
    def initialize(token, env, async_option = false)
      @token = token
      @env = env
      @async_option = async_option
      clear_queue
    end

    def append_event(event, properties = {})
      append_api('track', event, properties)
    end

    def append_api(type, *args)
      queue << [type, args.map {|arg| arg.to_json}]
    end

    def track_event(event, properties = {})
      params = build_event(event, properties.merge(:token => @token, :time => Time.now.utc.to_i, :ip => ip))
      parse_response request(params)
    end

    def ip
      @env.has_key?("REMOTE_ADDR") ? @env["REMOTE_ADDR"] : ""
    end

    def queue
      @env["mixpanel_events"]
    end

    def clear_queue
      @env["mixpanel_events"] = []
    end

    class <<self
      WORKER_MUTEX = Mutex.new

      def worker
        WORKER_MUTEX.synchronize do
          @worker || (@worker = IO.popen(self.cmd, 'w'))
        end
      end

      def dispose_worker(w)
        WORKER_MUTEX.synchronize do
          if(@worker == w)
            @worker = nil
            w.close
          end
        end
      end

      def cmd
        @cmd || begin
          require 'escape'
          require 'rbconfig'
          interpreter = File.join(*RbConfig::CONFIG.values_at("bindir", "ruby_install_name")) + RbConfig::CONFIG["EXEEXT"]
          subprocess  = File.join(File.dirname(__FILE__), 'tracker/subprocess.rb')
          @cmd = Escape.shell_command([interpreter, subprocess])
        end
      end
    end

    private

    def parse_response(response)
      response == "1" ? true : false
    end

    def request(params)
      data = Base64.encode64(JSON.generate(params)).gsub(/\n/,'')
      url = "http://api.mixpanel.com/track/?data=#{data}"

      if @async_option == true
        w = Tracker.worker
        begin
          url << "\n"
          w.write(url)
        rescue Errno::EPIPE => e
          Tracker.dispose_worker(w)
        end
      elsif @async_option.kind_of?(Module)
        @async_option.perform(url)
      else
        open(url).read
      end
    end

    def build_event(event, properties)
      {:event => event, :properties => properties}
    end
  end
end
