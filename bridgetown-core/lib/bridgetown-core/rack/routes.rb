# frozen_string_literal: true

module Bridgetown
  module Rack
    class Routes
      include Bridgetown::Prioritizable

      self.priorities = {
        highest: "010",
        high: "020",
        normal: "030",
        low: "040",
        lowest: "050",
      }.freeze

      class << self
        # rubocop:disable Bridgetown/NoPutsAllowed, Metrics/MethodLength
        def print_routes
          # TODO: this needs to be fully documented
          routes = begin
            JSON.parse(
              File.read(
                File.join(Bridgetown::Current.preloaded_configuration.root_dir, ".routes.json")
              )
            )
          rescue StandardError
            []
          end
          puts
          puts "Routes:"
          puts "======="
          if routes.blank?
            puts "No routes found. Have you commented all of your routes?"
            puts "Documentation: https://github.com/jeremyevans/roda-route_list#basic-usage-"
          end

          routes.each do |route|
            puts [
              route["methods"]&.join("|") || "GET",
              route["path"],
              route["file"] ? "\n  File: #{route["file"]}" : nil,
            ].compact.join(" ")
          end
          puts
        end
        # rubocop:enable Bridgetown/NoPutsAllowed, Metrics/MethodLength

        # @return [Hash<String, Class(Routes)>]
        attr_accessor :tracked_subclasses

        # @return [Proc]
        attr_accessor :router_block

        # Spaceship is priority [higher -> lower]
        #
        # @param other [Class(Routes)] The class to be compared.
        # @return [Integer] -1, 0, 1.
        def <=>(other)
          "#{priorities[priority]}#{self}" <=> "#{priorities[other.priority]}#{other}"
        end

        # @param base [Class(Routes)]
        def inherited(base)
          Bridgetown::Rack::Routes.track_subclass base
          super
        end

        # @param klass [Class(Routes)]
        def track_subclass(klass)
          Bridgetown::Rack::Routes.tracked_subclasses ||= {}
          Bridgetown::Rack::Routes.tracked_subclasses[klass.name] = klass
        end

        # @return [Array<Class(Routes)>]
        def sorted_subclasses
          Bridgetown::Rack::Routes.tracked_subclasses&.values&.sort
        end

        # @return [void]
        def reload_subclasses
          Bridgetown::Rack::Routes.tracked_subclasses&.each_key do |klassname|
            Kernel.const_get(klassname)
          rescue NameError
            Bridgetown::Rack::Routes.tracked_subclasses.delete klassname
          end
        end

        # Add a router block via the current Routes class
        #
        # Example:
        #
        #   class Routes::Hello < Bridgetown::Rack::Routes
        #     route do |r|
        #       r.get "hello", String do |name|
        #         { hello: "friend #{name}" }
        #       end
        #     end
        #   end
        #
        # @param block [Proc]
        def route(&block)
          self.router_block = block
        end

        # Initialize a new Routes instance and execute the route as part of the
        # Roda app request cycle
        #
        # @param roda_app [Roda]
        def merge(roda_app)
          return unless router_block

          new(roda_app).handle_routes
        end

        # Set up live reload if allowed, then run through all the Routes blocks.
        #
        # @param roda_app [Roda]
        # @return [void]
        def load_all(roda_app)
          if Bridgetown.env.development? &&
              !Bridgetown::Current.preloaded_configuration.skip_live_reload
            setup_live_reload roda_app
          end

          Bridgetown::Rack::Routes.sorted_subclasses&.each do |klass|
            klass.merge roda_app
          end
        end

        # @param app [Roda]
        def setup_live_reload(app) # rubocop:disable Metrics
          sleep_interval = 0.5
          file_to_check = File.join(Bridgetown::Current.preloaded_configuration.destination,
                                    "index.html")
          errors_file = Bridgetown.build_errors_path

          app.request.get "_bridgetown/live_reload" do
            @_mod = File.exist?(file_to_check) ? File.stat(file_to_check).mtime.to_i : 0
            event_stream = proc do |stream|
              Thread.new do
                loop do
                  new_mod = File.exist?(file_to_check) ? File.stat(file_to_check).mtime.to_i : 0

                  if @_mod < new_mod
                    stream.write "data: reloaded!\n\n"
                    break
                  elsif File.exist?(errors_file)
                    stream.write "event: builderror\ndata: #{File.read(errors_file).to_json}\n\n"
                  else
                    stream.write "data: #{new_mod}\n\n"
                  end

                  sleep sleep_interval
                rescue Errno::EPIPE # User refreshed the page
                  break
                end
              ensure
                stream.close
              end
            end

            app.request.halt [200, {
              "Content-Type"  => "text/event-stream",
              "cache-control" => "no-cache",
            }, event_stream,]
          end
        end
      end

      # @param roda_app [Roda]
      def initialize(roda_app)
        @_roda_app = roda_app
      end

      # Execute the router block via the instance, passing it the Roda request
      #
      # @return [Object] whatever is returned by the router block as expected
      #   by the Roda API
      def handle_routes
        instance_exec(@_roda_app.request, &self.class.router_block)
      end

      # Any missing methods are passed along to the underlying Roda app if possible
      def method_missing(method_name, ...)
        if @_roda_app.respond_to?(method_name.to_sym)
          @_roda_app.send(method_name.to_sym, ...)
        else
          super
        end
      end

      def respond_to_missing?(method_name, include_private = false)
        @_roda_app.respond_to?(method_name.to_sym, include_private) || super
      end
    end
  end
end
