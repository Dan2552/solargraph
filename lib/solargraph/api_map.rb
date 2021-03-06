require 'rubygems'
require 'parser/current'
require 'thread'
require 'set'

module Solargraph
  class ApiMap
    autoload :Config,       'solargraph/api_map/config'
    autoload :Source,       'solargraph/api_map/source'
    autoload :Cache,        'solargraph/api_map/cache'
    autoload :SourceToYard, 'solargraph/api_map/source_to_yard'
    @@source_cache = {}

    include NodeMethods
    include Solargraph::ApiMap::SourceToYard
    include CoreFills

    # The root directory of the project. The ApiMap will search here for
    # additional files to parse and analyze.
    #
    # @return [String]
    attr_reader :workspace

    # @param workspace [String]
    def initialize workspace = nil
      @@source_cache.clear
      @workspace = workspace.gsub(/\\/, '/') unless workspace.nil?
      clear
      require_extensions
      unless @workspace.nil?
        workspace_files.concat config.calculated
        workspace_files.each do |wf|
          begin
            @@source_cache[wf] ||= Source.load(wf)
          rescue Parser::SyntaxError => e
            STDERR.puts "Failed to load #{wf}: #{e.message}"
            @@source_cache[wf] = Source.virtual('', wf)
          end
        end
      end
      @sources = {}
      @virtual_source = nil
      @virtual_filename = nil
      @stale = true
      @yard_stale = true
      refresh
      yard_map
    end

    # Get the configuration for the ApiMap's workspace. This method will
    # initialize the settings from the workspace's root .solargraph.yml file
    # if it exists.
    #
    # @return [Solargraph::ApiMap::Config]
    def config reload = false
      @config = ApiMap::Config.new(@workspace) if @config.nil? or reload
      @config
    end

    # An array of all workspace files included in the map.
    #
    # @return[Array<String>]
    def workspace_files
      @workspace_files ||= []
    end

    # An array of required paths in the workspace.
    #
    # @return [Array<String>]
    def required
      @required ||= []
    end

    # Get a YardMap associated with the current namespace.
    #
    # @return [Solargraph::YardMap]
    def yard_map
      refresh
      if @yard_map.nil? || @yard_map.required.to_set != required.to_set
        @yard_map = Solargraph::YardMap.new(required: required, workspace: workspace)
      end
      @yard_map
    end

    # Get a LiveMap associated with the current namespace.
    #
    # @return [Solargraph::LiveMap]
    def live_map
      @live_map ||= Solargraph::LiveMap.new(self)
    end

    # @todo Get rid of the cursor parameter. Tracking stubbed lines is the
    #   better option.
    #
    # @param code [String]
    # @param filename [String]
    # @return [Solargraph::ApiMap::Source]
    def virtualize code, filename = nil, cursor = nil
      workspace_files.delete_if do |f|
        if File.exist?(f)
          false
        else
          eliminate f
          true
        end
      end
      if filename.nil? or filename.end_with?('.rb') or filename.end_with?('.erb')
        eliminate @virtual_filename unless @virtual_source.nil? or @virtual_filename == filename or workspace_files.include?(@virtual_filename)
        @virtual_filename = filename
        @virtual_source = Source.fix(code, filename, cursor)
        unless filename.nil? or workspace_files.include?(filename)
          current_files = @workspace_files
          @workspace_files = config(true).calculated
          (current_files - @workspace_files).each { |f| eliminate f }
        end
        process_virtual
      else
        unless filename.nil?
          # @todo Handle special files like .solargraph.yml
        end
      end
      @virtual_source
    end

    # @return [Solargraph::ApiMap::Source]
    def append_source code, filename
      virtualize code, filename
    end

    # Refresh the ApiMap.
    #
    # @param force [Boolean] Perform a refresh even if the map is not "stale."
    def refresh force = false
      process_maps if @stale or force
    end

    # True if a workspace file has been created, modified, or deleted since
    # the last time the map was processed.
    #
    # @return [Boolean]
    def changed?
      current = config.calculated
      unless (Set.new(current) ^ workspace_files).empty?
        return true
      end
      current.each do |f|
        if !File.exist?(f) or File.mtime(f) != source_file_mtime(f)
          return true
        end
      end
      false
    end

    # Get the docstring associated with a node.
    #
    # @param node [AST::Node]
    # @return [YARD::Docstring]
    def get_docstring_for node
      filename = get_filename_for(node)
      return nil if @sources[filename].nil?
      @sources[filename].docstring_for(node)
    end

    # An array of suggestions based on Ruby keywords (`if`, `end`, etc.).
    #
    # @return [Array<Solargraph::Suggestion>]
    def self.keywords
      @keyword_suggestions ||= KEYWORDS.map{ |s|
        Suggestion.new(s.to_s, kind: Suggestion::KEYWORD, detail: 'Keyword')
      }.freeze
    end

    # An array of namespace names defined in the ApiMap.
    #
    # @return [Array<String>]
    def namespaces
      refresh
      namespace_map.keys
    end

    # True if the namespace exists.
    #
    # @param name [String] The namespace to match
    # @param root [String] The context to search
    # @return [Boolean]
    def namespace_exists? name, root = ''
      !find_fully_qualified_namespace(name, root).nil?
    end

    # Get an array of constant pins defined in the ApiMap. (This method does
    # not include constants from external gems or the Ruby core.)
    #
    # @param namespace [String] The namespace to match
    # @param root [String] The context to search
    # @return [Array<Solargraph::Pin::Constant>]
    def get_constant_pins namespace, root
      fqns = find_fully_qualified_namespace(namespace, root)
      @const_pins[fqns] || []
    end

    # Get suggestions for constants in the specified namespace. The result
    # will include constant variables, classes, and modules.
    #
    # @param namespace [String] The namespace to match
    # @param root [String] The context to search
    # @return [Array<Solargraph::Suggestion>]
    def get_constants namespace, root = ''
      result = []
      skip = []
      fqns = find_fully_qualified_namespace(namespace, root)
      return [] if fqns.nil?
      if fqns.empty?
        result.concat inner_get_constants('', skip, false, [:public])
      else
        parts = fqns.split('::')
        while parts.length > 0
          resolved = find_namespace_pins(parts.join('::'))
          resolved.each do |pin|
            visi = [:public]
            visi.push :private if namespace == '' and root != '' and pin.path == fqns
            result.concat inner_get_constants(pin.path, skip, true, visi)
          end
          parts.pop
          break unless namespace.empty?
        end
        result.concat inner_get_constants('', [], false) if namespace.empty?
      end
      result.concat yard_map.get_constants(fqns)
      result
    end

    # Get a fully qualified namespace name. This method will start the search
    # in the specified root until it finds a match for the name.
    #
    # @param name [String] The namespace to match
    # @param root [String] The context to search
    # @return [String]
    def find_fully_qualified_namespace name, root = '', skip = []
      refresh
      return nil if skip.include?(root)
      skip.push root
      if name == ''
        if root == ''
          return ''
        else
          return find_fully_qualified_namespace(root, '', skip)
        end
      else
        if (root == '')
          return name unless namespace_map[name].nil?
          get_include_strings_from(*file_nodes).each { |i|
            reroot = "#{root == '' ? '' : root + '::'}#{i}"
            recname = find_fully_qualified_namespace name.to_s, reroot, skip
            return recname unless recname.nil?
          }
        else
          roots = root.to_s.split('::')
          while roots.length > 0
            fqns = roots.join('::') + '::' + name
            return fqns unless namespace_map[fqns].nil?
            roots.pop
          end
          return name unless namespace_map[name].nil?
          get_include_strings_from(*file_nodes).each { |i|
            recname = find_fully_qualified_namespace name, i, skip
            return recname unless recname.nil?
          }
        end
      end
      result = yard_map.find_fully_qualified_namespace(name, root)
      if result.nil?
        result = live_map.get_fqns(name, root)
      end
      result
    end

    # Get an array of instance variable pins defined in specified namespace
    # and scope.
    #
    # @param namespace [String] A fully qualified namespace
    # @param scope [Symbol] :instance or :class
    # @return [Array<Solargraph::Pin::InstanceVariable>]
    def get_instance_variable_pins(namespace, scope = :instance)
      refresh
      (@ivar_pins[namespace] || []).select{ |pin| pin.scope == scope }
    end

    # Get an array of instance variable suggestions defined in specified
    # namespace and scope.
    #
    # @param namespace [String] A fully qualified namespace
    # @param scope [Symbol] :instance or :class
    # @return [Array<Solargraph::Suggestion>]
    def get_instance_variables(namespace, scope = :instance)
      refresh
      result = []
      ip = @ivar_pins[namespace]
      unless ip.nil?
        result.concat suggest_unique_variables(ip.select{ |pin| pin.scope == scope })
      end
      result
    end

    # @return [Array<Solargraph::Pin::ClassVariable>]
    def get_class_variable_pins(namespace)
      refresh
      @cvar_pins[namespace] || []
    end

    # @return [Array<Solargraph::Suggestion>]
    def get_class_variables(namespace)
      refresh
      result = []
      cp = @cvar_pins[namespace]
      unless cp.nil?
        result.concat suggest_unique_variables(cp)
      end
      result
    end

    # @return [Array<Solargraph::Pin::Symbol>]
    def get_symbols
      refresh
      @symbol_pins.uniq(&:label)
    end

    # @return [String]
    def get_filename_for(node)
      @sources.each do |filename, source|
        return source.filename if source.include?(node)
      end
      nil
    end

    # @return [Solargraph::ApiMap::Source]
    def get_source_for(node)
      @sources.each do |filename, source|
        return source if source.include?(node)
      end
      nil
    end

    # @return [String]
    def infer_instance_variable(var, namespace, scope)
      refresh
      pins = @ivar_pins[namespace]
      return nil if pins.nil?
      pin = pins.select{|p| p.name == var and p.scope == scope}.first
      return nil if pin.nil?
      type = nil
      type = find_fully_qualified_namespace(pin.return_type, pin.namespace) unless pin.return_type.nil?
      if type.nil?
        zparts = resolve_node_signature(pin.assignment_node).split('.')
        ztype = infer_signature_type(zparts[0..-2].join('.'), namespace, scope: :instance, call_node: pin.assignment_node)
        type = get_return_type_from_macro(ztype, zparts[-1], pin.assignment_node, :instance, [:public, :private, :protected])
      end
      type
    end

    # @return [String]
    def infer_class_variable(var, namespace)
      refresh
      fqns = find_fully_qualified_namespace(namespace)
      pins = @cvar_pins[fqns]
      return nil if pins.nil?
      pin = pins.select{|p| p.name == var}.first
      return nil if pin.nil? or pin.return_type.nil?
      find_fully_qualified_namespace(pin.return_type, pin.namespace)
    end

    # @return [Array<Solargraph::Suggestion>]
    def get_global_variables
      globals = []
      @sources.values.each do |s|
        globals.concat s.global_variable_pins
      end
      suggest_unique_variables globals
    end

    # @return [Array<Solargraph::Pin::GlobalVariable>]
    def get_global_variable_pins
      globals = []
      @sources.values.each do |s|
        globals.concat s.global_variable_pins
      end
      globals
    end

    # @return [String]
    def infer_assignment_node_type node, namespace
      cached = cache.get_assignment_node_type(node, namespace)
      return cached unless cached.nil?
      name_i = (node.type == :casgn ? 1 : 0) 
      sig_i = (node.type == :casgn ? 2 : 1)
      type = infer_literal_node_type(node.children[sig_i])
      if type.nil?
        sig = resolve_node_signature(node.children[sig_i])
        # Avoid infinite loops from variable assignments that reference themselves
        return nil if node.children[name_i].to_s == sig.split('.').first
        type = infer_signature_type(sig, namespace, call_node: node.children[sig_i])
      end
      cache.set_assignment_node_type(node, namespace, type)
      type
    end

    def get_call_arguments node
      return [] unless node.type == :send
      result = []
      node.children[2..-1].each do |c|
        result.push unpack_name(c)
      end
      result
    end

    # Get the return type for a signature within the specified namespace and
    # scope.
    #
    # @example
    #   api_map.infer_signature_type('String.new', '') #=> 'String'
    #
    # @param signature [String]
    # @param namespace [String] A fully qualified namespace
    # @param scope [Symbol] :class or :instance
    # @return [String]
    def infer_signature_type signature, namespace, scope: :class, call_node: nil
      namespace ||= ''
      if cache.has_signature_type?(signature, namespace, scope)
        return cache.get_signature_type(signature, namespace, scope)
      end
      return nil if signature.nil?
      return namespace if signature.empty? and scope == :instance
      return nil if signature.empty? # @todo This might need to return Class<namespace>
      if !signature.include?('.')
        fqns = find_fully_qualified_namespace(signature, namespace)
        unless fqns.nil? or fqns.empty?
          type = (get_namespace_type(fqns) == :class ? 'Class' : 'Module')
          return "#{type}<#{fqns}>"
        end
      end
      result = nil
      if namespace.end_with?('#class')
        result = infer_signature_type signature, namespace[0..-7], scope: (scope == :class ? :instance : :class), call_node: call_node
      else
        parts = signature.split('.', 2)
        if parts[0].start_with?('@@')
          type = infer_class_variable(parts[0], namespace)
          if type.nil? or parts.empty?
            result = inner_infer_signature_type(parts[1], type, scope: :instance, call_node: call_node)
          else
            result = type
          end
        elsif parts[0].start_with?('@')
          type = infer_instance_variable(parts[0], namespace, scope)
          if type.nil? or parts.empty?
            result = inner_infer_signature_type(parts[1], type, scope: :instance, call_node: call_node)
          else
            result = type
          end
        else
          type = find_fully_qualified_namespace(parts[0], namespace)
          if type.nil?
            # It's a method call
            type = inner_infer_signature_type(parts[0], namespace, scope: scope, call_node: call_node)
            if parts.length < 2
              if type.nil? and !parts.length.nil?
                path = "#{clean_namespace_string(namespace)}#{scope == :class ? '.' : '#'}#{parts[0]}"
                subtypes = get_subtypes(namespace)
                type = subtypes[0] if METHODS_RETURNING_SUBTYPES.include?(path)
              end
              result = type
            else
              result = inner_infer_signature_type(parts[1], type, scope: :instance, call_node: call_node)
            end
          else
            result = inner_infer_signature_type(parts[1], type, scope: :class, call_node: call_node)
          end
          result = type if result == 'self'
        end
      end
      cache.set_signature_type signature, namespace, scope, result
      result
    end

    # Get the namespace's type (Class or Module).
    #
    # @param [String] A fully qualified namespace
    # @return [Symbol] :class, :module, or nil
    def get_namespace_type fqns
      return nil if fqns.nil?
      type = nil
      nodes = get_namespace_nodes(fqns)
      unless nodes.nil? or nodes.empty? or !nodes[0].kind_of?(AST::Node)
        type = nodes[0].type if [:class, :module].include?(nodes[0].type)
      end
      if type.nil?
        type = yard_map.get_namespace_type(fqns)
      end
      type
    end

    # Get an array of singleton methods that are available in the specified
    # namespace.
    #
    # @return [Array<Solargraph::Suggestion>]
    def get_methods(namespace, root = '', visibility: [:public])
      refresh
      namespace = clean_namespace_string(namespace)
      fqns = find_fully_qualified_namespace(namespace, root)
      meths = []
      skip = []
      meths.concat inner_get_methods(namespace, root, skip, visibility)
      yard_meths = yard_map.get_methods(fqns, '', visibility: visibility)
      if yard_meths.any?
        meths.concat yard_meths
      else
        type = get_namespace_type(fqns)
        if type == :class
          meths.concat yard_map.get_instance_methods('Class')
        else
          meths.concat yard_map.get_instance_methods('Module')
        end
      end
      news = meths.select{|s| s.label == 'new'}
      unless news.empty?
        if @method_pins[fqns]
          inits = @method_pins[fqns].select{|p| p.name == 'initialize'}
          meths -= news unless inits.empty?
          inits.each do |pin|
            meths.push Suggestion.new('new', kind: pin.kind, docstring: pin.docstring, detail: pin.namespace, arguments: pin.parameters, path: pin.path)
          end
        end
      end
      if namespace == '' and root == ''
        config.domains.each do |d|
          meths.concat get_instance_methods(d)
        end
      end
      strings = meths.map(&:to_s)
      live_map.get_methods(fqns, '', 'class', visibility.include?(:private)).each do |ls|
        next if strings.include?(ls.to_s)
        meths.push ls
      end
      meths
    end

    # Get an array of instance methods that are available in the specified
    # namespace.
    #
    # @return [Array<Solargraph::Suggestion>]
    def get_instance_methods(namespace, root = '', visibility: [:public])
      refresh
      namespace = clean_namespace_string(namespace)
      if namespace.end_with?('#class') or namespace.end_with?('#module')
        return get_methods(namespace.split('#').first, root, visibility: visibility)
      end
      meths = []
      meths += inner_get_instance_methods(namespace, root, [], visibility) #unless has_yardoc?
      fqns = find_fully_qualified_namespace(namespace, root)
      yard_meths = yard_map.get_instance_methods(fqns, '', visibility: visibility)
      if yard_meths.any?
        meths.concat yard_meths
      else
        type = get_namespace_type(fqns)
        if type == :class
          meths += yard_map.get_instance_methods('Object')
        elsif type == :module
          meths += yard_map.get_instance_methods('Module')
        end
      end
      if namespace == '' and root == ''
        config.domains.each do |d|
          meths.concat get_instance_methods(d)
        end
      end
      strings = meths.map(&:to_s)
      live_map.get_methods(fqns, '', 'class', visibility.include?(:private)).each do |ls|
        next if strings.include?(ls.to_s)
        meths.push ls
      end
      meths
    end

    # Update the ApiMap with the most recent version of the specified file.
    #
    # @param filename [String]
    def update filename
      filename.gsub!(/\\/, '/')
      if filename.end_with?('.rb')
        if @virtual_filename == filename
          @virtual_filename = nil
          @virtual_source = nil
        end
        if @workspace_files.include?(filename)
          eliminate filename
          @@source_cache[filename] = Source.load(filename)
          @sources.delete filename
          @sources[filename] = @@source_cache[filename]
          rebuild_local_yardoc #if @workspace_files.include?(filename)
          @stale = true
        else
          @workspace_files = config(true).calculated
          update filename if @workspace_files.include?(filename)
        end
      elsif File.basename(filename) == '.solargraph.yml'
        # @todo Finish refreshing the map
        @workspace_files = config(true).calculated
      end
    end

    # All sources generated from workspace files.
    #
    # @return [Array<Solargraph::ApiMap::Source>]
    def sources
      @sources.values
    end

    # Get an array of all suggestions that match the specified path.
    #
    # @param path [String] The path to find
    # @return [Array<Solargraph::Suggestion>]
    def get_path_suggestions path
      refresh
      result = []
      if path.include?('#')
        # It's an instance method
        parts = path.split('#')
        result = get_instance_methods(parts[0], '', visibility: [:public, :private, :protected]).select{|s| s.label == parts[1]}
      elsif path.include?('.')
        # It's a class method
        parts = path.split('.')
        result = get_methods(parts[0], '', visibility: [:public, :private, :protected]).select{|s| s.label == parts[1]}
      else
        # It's a class or module
        parts = path.split('::')
        np = @namespace_pins[parts[0..-2].join('::')]
        unless np.nil?
          result.concat np.select{|p| p.name == parts.last}.map{|p| pin_to_suggestion(p)}
        end
        result.concat yard_map.objects(path)
      end
      result
    end

    # Get a list of documented paths that match the query.
    #
    # @example
    #   api_map.query('str') # Results will include `String` and `Struct`
    #
    # @param query [String] The text to match
    # @return [Array<String>]
    def search query
      refresh
      rake_yard(@sources.values) if @yard_stale
      @yard_stale = false
      found = []
      code_object_paths.each do |k|
        if found.empty? or (query.include?('.') or query.include?('#')) or !(k.include?('.') or k.include?('#'))
          found.push k if k.downcase.include?(query.downcase)
        end
      end
      found.concat(yard_map.search(query)).uniq.sort
    end

    # Get YARD documentation for the specified path.
    #
    # @example
    #   api_map.document('String#split')
    #
    # @param path [String] The path to find
    # @return [Array<YARD::CodeObject::Base>]
    def document path
      refresh
      rake_yard(@sources.values) if @yard_stale
      @yard_stale = false
      docs = []
      docs.push code_object_at(path) unless code_object_at(path).nil?
      docs.concat yard_map.document(path)
      docs
    end

    private

    # @return [Hash]
    def namespace_map
      @namespace_map ||= {}
    end

    def clear
      @stale = false
      namespace_map.clear
      path_macros.clear
      @required = config.required.clone
    end

    def process_maps
      process_workspace_files
      cache.clear
      @ivar_pins = {}
      @cvar_pins = {}
      @const_pins = {}
      @method_pins = {}
      @symbol_pins = []
      @attr_pins = {}
      @namespace_includes = {}
      @namespace_extends = {}
      @superclasses = {}
      @namespace_pins = {}
      namespace_map.clear
      @required = config.required.clone
      @pin_suggestions = {}
      unless @virtual_source.nil?
        @sources[@virtual_filename] = @virtual_source
      end
      @sources.values.each do |s|
        s.namespace_nodes.each_pair do |k, v|
          namespace_map[k] ||= []
          namespace_map[k].concat v
        end
      end
      @sources.values.each { |s|
        map_source s
      }
      @required.uniq!
      live_map.refresh
      @stale = false
      @yard_stale = true
    end

    def rebuild_local_yardoc
      return if workspace.nil? or !File.exist?(File.join(workspace, '.yardoc'))
      STDERR.puts "Rebuilding local yardoc for #{workspace}"
      Dir.chdir(workspace) { Process.spawn('yardoc') }
    end

    def process_workspace_files
      @sources.clear
      workspace_files.each do |f|
        if File.file?(f)
          begin
            @@source_cache[f] ||= Source.load(f)
            @sources[f] = @@source_cache[f]
          rescue Exception => e
            STDERR.puts "Failed to load #{f}: #{e.message}"
          end
        end
      end
    end

    def process_virtual
      unless @virtual_source.nil?
        cache.clear
        namespace_map.clear
        @sources[@virtual_filename] = @virtual_source
        @sources.values.each do |s|
          s.namespace_nodes.each_pair do |k, v|
            namespace_map[k] ||= []
            namespace_map[k].concat v
          end
        end
        eliminate @virtual_filename
        map_source @virtual_source
      end
    end

    def eliminate filename
      [@ivar_pins.values, @cvar_pins.values, @const_pins.values, @method_pins.values, @attr_pins.values, @namespace_pins.values].each do |pinsets|
        pinsets.each do |pins|
          pins.delete_if{|pin| pin.filename == filename}
        end
      end
      #@symbol_pins.delete_if{|pin| pin.filename == filename}
    end

    # @param [Solargraph::ApiMap::Source]
    def map_source source
      source.method_pins.each do |pin|
        @method_pins[pin.namespace] ||= []
        @method_pins[pin.namespace].push pin
      end
      source.attribute_pins.each do |pin|
        @attr_pins[pin.namespace] ||= []
        @attr_pins[pin.namespace].push pin
      end
      source.instance_variable_pins.each do |pin|
        @ivar_pins[pin.namespace] ||= []
        @ivar_pins[pin.namespace].push pin
      end
      source.class_variable_pins.each do |pin|
        @cvar_pins[pin.namespace] ||= []
        @cvar_pins[pin.namespace].push pin
      end
      source.constant_pins.each do |pin|
        @const_pins[pin.namespace] ||= []
        @const_pins[pin.namespace].push pin
      end
      source.symbol_pins.each do |pin|
        @symbol_pins.push Suggestion.new(pin.name, kind: Suggestion::CONSTANT, return_type: 'Symbol')
      end
      source.namespace_includes.each_pair do |ns, i|
        @namespace_includes[ns] ||= []
        @namespace_includes[ns].concat(i).uniq!
      end
      source.namespace_extends.each_pair do |ns, e|
        @namespace_extends[ns || ''] ||= []
        @namespace_extends[ns || ''].concat(e).uniq!
      end
      source.superclasses.each_pair do |cls, sup|
        @superclasses[cls] = sup
      end
      source.namespace_pins.each do |pin|
        @namespace_pins[pin.namespace] ||= []
        @namespace_pins[pin.namespace].push pin
      end
      path_macros.merge! source.path_macros
      source.required.each do |r|
        required.push r
      end
    end

    # @return [Solargraph::ApiMap::Cache]
    def cache
      @cache ||= Cache.new
    end

    def inner_get_methods(namespace, root = '', skip = [], visibility = [:public])
      meths = []
      return meths if skip.include?(namespace)
      skip.push namespace
      fqns = find_fully_qualified_namespace(namespace, root)
      return meths if fqns.nil?
      mn = @method_pins[fqns]
      unless mn.nil?
        mn.select{ |pin| pin.scope == :class }.each do |pin|
          meths.push pin_to_suggestion(pin) if visibility.include?(pin.visibility)
        end
      end
      if visibility.include?(:public) or visibility.include?(:protected)
        sc = @superclasses[fqns]
        unless sc.nil?
          sc_visi = [:public]
          sc_visi.push :protected if root == fqns
          nfqns = find_fully_qualified_namespace(sc, fqns)
          meths.concat inner_get_methods('', nfqns, skip, sc_visi)
          meths.concat yard_map.get_methods(nfqns, '', visibility: sc_visi)
        end
      end
      em = @namespace_extends[fqns]
      unless em.nil?
        em.each do |e|
          meths.concat get_instance_methods(e, fqns, visibility: visibility)
        end
      end
      meths.uniq
    end

    def inner_get_instance_methods(namespace, root, skip, visibility = [:public])
      fqns = find_fully_qualified_namespace(namespace, root)
      meths = []
      return meths if skip.include?(fqns)
      skip.push fqns
      an = @attr_pins[fqns]
      unless an.nil?
        an.each do |pin|
          meths.push pin_to_suggestion(pin)
        end
      end
      mn = @method_pins[fqns]
      unless mn.nil?
        mn.select{|pin| visibility.include?(pin.visibility) and pin.scope == :instance }.each do |pin|
          meths.push pin_to_suggestion(pin)
        end
      end
      if visibility.include?(:public) or visibility.include?(:protected)
        sc = @superclasses[fqns]
        unless sc.nil?
          sc_visi = [:public]
          sc_visi.push :protected if sc == fqns
          nfqns = find_fully_qualified_namespace(sc, fqns)
          meths.concat inner_get_instance_methods('', nfqns, skip, sc_visi)
          meths.concat yard_map.get_instance_methods(nfqns, '', visibility: sc_visi)
        end
      end
      im = @namespace_includes[fqns]
      unless im.nil?
        im.each do |i|
          nfqns = find_fully_qualified_namespace(i, fqns)
          meths.concat inner_get_instance_methods('', nfqns, skip, visibility)
        end
      end
      meths.uniq
    end

    # Get a fully qualified namespace for the given signature.
    # The signature should be in the form of a method chain, e.g.,
    # method1.method2
    #
    # @return [String] The fully qualified namespace for the signature's type
    #   or nil if a type could not be determined
    def inner_infer_signature_type signature, namespace, scope: :instance, top: true, call_node: nil
      return nil if signature.nil?
      signature.gsub!(/\.$/, '')
      if signature.empty?
        if scope == :class
          type = get_namespace_type(namespace)
          if type == :class
            return "Class<#{namespace}>"
          else
            return "Module<#{namespace}>"
          end
        end
      end
      parts = signature.split('.')
      type = namespace || ''
      while (parts.length > 0)
        part = parts.shift
        if top == true and part == 'self'
          top = false
          next
        end
        cls_match = type.match(/^Class<([A-Za-z0-9_:]*?)>$/)
        if cls_match
          type = cls_match[1]
          scope = :class
        end
        if scope == :class and part == 'new'
          scope = :instance
        else
          curtype = type
          type = nil
          visibility = [:public]
          visibility.concat [:private, :protected] if top
          if scope == :instance || namespace == ''
            tmp = get_instance_methods(namespace, visibility: visibility)
          else
            tmp = get_methods(namespace, visibility: visibility)
          end
          tmp.concat get_instance_methods('Kernel', visibility: [:public]) if top
          matches = tmp.select{|s| s.label == part}
          return nil if matches.empty?
          matches.each do |m|
            type = get_return_type_from_macro(namespace, signature, call_node, scope, visibility)
            if type.nil?
              if METHODS_RETURNING_SELF.include?(m.path)
                type = curtype
              elsif METHODS_RETURNING_SUBTYPES.include?(m.path)
                subtypes = get_subtypes(namespace)
                type = subtypes[0]
              else
                type = m.return_type
              end
            end
            break unless type.nil?
          end
          scope = :instance
        end
        top = false
      end
      if scope == :class and !type.nil?
        type = "Class<#{type}>"
      end
      type
    end

    def inner_get_constants here, skip = [], deep = true, visibility = [:public]
      return [] if skip.include?(here)
      skip.push here
      result = []
      cp = @const_pins[here]
      unless cp.nil?
        cp.each do |pin|
          result.push pin_to_suggestion(pin) if pin.visibility == :public or visibility.include?(:private)
        end
      end
      np = @namespace_pins[here]
      unless np.nil?
        np.each do |pin|
          if pin.visibility == :public || visibility.include?(:private)
            result.push pin_to_suggestion(pin)
            if deep
              get_include_strings_from(pin.node).each do |i|
                result.concat inner_get_constants(i, skip, false, [:public])
              end
            end
          end
        end
      end
      get_include_strings_from(*get_namespace_nodes(here)).each do |i|
        result.concat inner_get_constants(i, skip, false, [:public])
      end
      result
    end

    # @return [AST::Node]
    def file_nodes
      @sources.values.map(&:node)
    end

    # @param namespace [String]
    # @return [String]
    def clean_namespace_string namespace
      result = namespace.to_s.gsub(/<.*$/, '')
      if result == 'Class' and namespace.include?('<')
        subtype = namespace.match(/<([a-z0-9:_]*)/i)[1]
        result = "#{subtype}#class"
      elsif result == 'Module' and namespace.include?('<')
        subtype = namespace.match(/<([a-z0-9:_]*)/i)[1]
        result = "#{subtype}#module"
      end
      result
    end

    # @param pin [Solargraph::Pin::Base]
    # @return [Solargraph::Suggestion]
    def pin_to_suggestion pin
      return_type = nil
      return_type = find_fully_qualified_namespace(pin.return_type, pin.namespace) unless pin.return_type.nil?
      if return_type.nil? and pin.is_a?(Solargraph::Pin::Method)
        sc = @superclasses[pin.namespace]
        while return_type.nil? and !sc.nil?
          sc_path = "#{sc}#{pin.scope == :instance ? '#' : '.'}#{pin.name}"
          sugg = get_path_suggestions(sc_path).first
          break if sugg.nil?
          return_type = find_fully_qualified_namespace(sugg.return_type, sugg.namespace) unless sugg.return_type.nil?
          sc = @superclasses[sc]
        end
      end
      @pin_suggestions[pin] ||= Suggestion.pull(pin, return_type)
    end

    def require_extensions
      Gem::Specification.all_names.select{|n| n.match(/^solargraph\-[a-z0-9_\-]*?\-ext\-[0-9\.]*$/)}.each do |n|
        STDERR.puts "Loading extension #{n}"
        require n.match(/^(solargraph\-[a-z0-9_\-]*?\-ext)\-[0-9\.]*$/)[1]
      end
    end

    def suggest_unique_variables pins
      result = []
      nil_pins = []
      val_names = []
      pins.each do |pin|
        if pin.nil_assignment? and pin.return_type.nil?
          nil_pins.push pin
        else
          unless val_names.include?(pin.name)
            result.push pin_to_suggestion(pin)
            val_names.push pin.name
          end
        end
      end
      nil_pins.reject{|p| val_names.include?(p.name)}.each do |pin|
        result.push pin_to_suggestion(pin)
      end
      result
    end

    def source_file_mtime(filename)
      # @todo This is naively inefficient.
      sources.each do |s|
        return s.mtime if s.filename == filename
      end
      nil
    end

    # @return [Array<Solargraph::Pin::Namespace>]
    def find_namespace_pins fqns
      set = nil
      if fqns.include?('::')
        set = @namespace_pins[fqns.split('::')[0..-2].join('::')]
      else
        set = @namespace_pins['']
      end
      return [] if set.nil?
      set.select{|p| p.path == fqns}
    end

    def get_namespace_nodes(fqns)
      return file_nodes if fqns == '' or fqns.nil?
      refresh
      namespace_map[fqns] || []
    end

    # @return [Array<String>]
    def get_include_strings_from *nodes
      arr = []
      nodes.each { |node|
        next unless node.kind_of?(AST::Node)
        arr.push unpack_name(node.children[2]) if (node.type == :send and node.children[1] == :include)
        node.children.each { |n|
          arr += get_include_strings_from(n) if n.kind_of?(AST::Node) and n.type != :class and n.type != :module and n.type != :sclass
        }
      }
      arr
    end

    # @todo DRY this method. It's duplicated in CodeMap
    def get_subtypes type
      return nil if type.nil?
      match = type.match(/<([a-z0-9_:, ]*)>/i)
      return [] if match.nil?
      match[1].split(',').map(&:strip)
    end

    # @return [Hash]
    def path_macros
      @path_macros ||= {}
    end

    def get_return_type_from_macro namespace, signature, call_node, scope, visibility
      return nil if signature.empty? or signature.include?('.') or call_node.nil?
      path = "#{namespace}#{scope == :class ? '.' : '#'}#{signature}"
      macmeth = get_path_suggestions(path).first
      type = nil
      unless macmeth.nil?
        macro = path_macros[macmeth.path]
        macro = macro.first unless macro.nil?
        if macro.nil? and !macmeth.code_object.nil? and !macmeth.code_object.base_docstring.nil? and macmeth.code_object.base_docstring.all.include?('@!macro')
          all = YARD::Docstring.parser.parse(macmeth.code_object.base_docstring.all).directives
          macro = all.select{|m| m.tag.tag_name == 'macro'}.first
        end
        unless macro.nil?
          docstring = YARD::Docstring.parser.parse(macro.tag.text).to_docstring
          rt = docstring.tag(:return)
          unless rt.nil? or rt.types.nil? or call_node.nil?
            args = get_call_arguments(call_node)
            type = "#{args[rt.types[0][1..-1].to_i-1]}"
          end
        end
      end
      type
    end
  end
end
