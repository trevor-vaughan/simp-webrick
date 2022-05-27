module Simp; end
module Simp::PuppetExtensions
  require 'find'

  Find.find(File.join(__dir__, 'puppet_extensions')) do |path|
    require_relative path if path[-3..-1] == '.rb'
  end
end
