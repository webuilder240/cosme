module Cosme
  class Middleware
    include ActionView::Helpers::TagHelper
    include Cosme::Helpers

    def initialize(app)
      @app = app
    end

    def call(env)
      @env = env

      response = @app.call(env)
      return response unless Cosme.auto_cosmeticize?

      html = response_to_html(response)
      return response unless html

      new_html = insert_cosmeticize_tag(html)
      new_html = insert_cosme_js(new_html)
      new_response(response, new_html)
    end

    private

    def response_to_html(response)
      status, headers, body = response
      return if status != 200
      return unless html_headers? headers
      take_html(body)
    end

    def insert_cosmeticize_tag(html)
      cosmeticizer = cosmeticize(controller)
      html.sub(/<body[^>]*>/) { [$~, cosmeticizer].join }
    end

    def insert_cosme_js(html)
      view_context = controller.try(:view_context)
      return html unless view_context
      script = view_context.javascript_include_tag('cosme', 'data-turbolinks-track' => true)
      html.sub(/<\/head>/) { [script, $~].join }
    end

    def new_response(response, new_html)
      status, headers, _ = response
      headers['Content-Length'] = new_html.bytesize.to_s
      [status, headers, [new_html]]
    end

    def html_headers?(headers)
      return false unless headers['Content-Type']
      return false unless headers['Content-Type'].include? 'text/html'
      return false if headers['Content-Transfer-Encoding'] == 'binary'
      true
    end

    # body is one of the following:
    #   - Array
    #   - ActionDispatch::Response
    #   - ActionDispatch::Response::RackBody
    def take_html(body)
      strings = []
      body.each { |buf| strings << buf }
      strings.join
    end

    # Use in Cosme::Helpers#cosmeticize
    def render(options = {})
      _helpers = helpers
      view_context = ActionView::Base.new(ActionController::Base.view_paths, assigns, controller)
      view_context.class_eval { _helpers.each { |h| include h } }
      view_context.render(options)
    end

    def controller
      return unless @env
      @env['action_controller.instance']
    end

    def assigns
      return {} unless controller
      controller.view_context.assigns
    end

    def helpers
      [
        controller.try(:_helpers),
        Rails.application.routes.url_helpers,
        engines_helpers
      ].compact
    end

    def engines_helpers
      wodule = Module.new

      isolated_engine_instances.each do |instance|
        name = instance.engine_name

        wodule.class_eval do
          define_method "_#{name}" do
            instance.routes.url_helpers
          end
        end

        wodule.class_eval(<<-RUBY, __FILE__, __LINE__ + 1)
          def #{name}
            @_#{name} ||= _#{name}
          end
        RUBY
      end

      wodule
    end

    def isolated_engine_instances
      Rails::Engine.subclasses.map(&:instance).select(&:isolated?)
    end
  end
end
