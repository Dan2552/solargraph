require 'solargraph/version'
require 'rubygems/package'
require 'yard-solargraph'

module Solargraph
  autoload :Shell,         'solargraph/shell'
  autoload :ApiMap,        'solargraph/api_map'
  autoload :CodeMap,       'solargraph/code_map'
  autoload :NodeMethods,   'solargraph/node_methods'
  autoload :Suggestion,    'solargraph/suggestion'
  autoload :Server,        'solargraph/server'
  autoload :YardMap,       'solargraph/yard_map'
  autoload :Pin,           'solargraph/pin'
  autoload :LiveMap,       'solargraph/live_map'
  autoload :ServerMethods, 'solargraph/server_methods'
  autoload :Plugin,        'solargraph/plugin'
  autoload :CoreFills,     'solargraph/core_fills'

  YARDOC_PATH = File.join(File.realpath(File.dirname(__FILE__)), '..', 'yardoc')
  YARD_EXTENSION_FILE = File.join(File.realpath(File.dirname(__FILE__)), 'yard-solargraph.rb')
end

Solargraph::YardMap::CoreDocs.require_minimum
