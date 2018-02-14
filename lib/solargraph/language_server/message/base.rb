module Solargraph
  module LanguageServer
    module Message
      class Base
        # @return [Solargraph::LanguageServer::Host]
        attr_reader :host
        attr_reader :id
        attr_reader :method
        attr_reader :params
        attr_reader :result
        attr_reader :error

        def initialize host, request
          @host = host
          @id = request['id']
          @method = request['method']
          @params = request['params']
          post_initialize
        end

        def post_initialize
        end

        def process
        end

        def set_result data
          @result = data
        end

        def set_error data
          @error = data
        end

        def response
          response = {}
          response[:result] = result unless result.nil?
          response[:error] = error unless error.nil?
          response
        end

        def send
          unless id.nil? or host.cancel?(id)
            response = {
              jsonrpc: "2.0",
              id: id,
            }
            response[:result] = result unless result.nil?
            response[:error] = error unless error.nil?
            json = response.to_json
            # @todo Why does \n\n work but \r\n\r\n doesn't?
            envelope = "Content-Length: #{json.bytesize}\r\n\r\n#{json}"
            #STDOUT.print envelope
            #STDOUT.flush
            host.queue envelope
          end
          host.clear id
        end
      end
    end
  end
end