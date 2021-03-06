module Solargraph
  module Pin
    module Directed
      class Method < Solargraph::Pin::Method
        def initialize source, node, namespace, scope, visibility, docstring, name
          super(source, node, namespace, scope, visibility)
          @docstring = docstring
          @name = name
        end

        def name
          @name
        end
      end
    end
  end
end
