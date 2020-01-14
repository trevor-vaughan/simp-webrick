# -*- encoding: utf-8 -*-
$LOAD_PATH.unshift File.expand_path('../lib', __FILE__)
require 'simp/webrick/version'
require 'date'

Gem::Specification.new do |s|
  s.name        = 'simp-webrick'
  s.date        = Date.today.to_s
  s.summary     = 'Adding webrick back to Puppet'
  s.description = <<-EOF
    We missed you webrick
  EOF
  s.version     = Simp::Webrick::VERSION
  s.license     = 'Apache-2.0'
  s.authors     = ['Trevor Vaughan']
  s.email       = 'simp@simp-project.org'
  s.homepage    = 'https://github.com/simp/rubygem-simp-webrick'
  s.metadata = {
                 'issue_tracker' => 'https://simp-project.atlassian.net'
               }
  s.add_runtime_dependency 'puppet'                    , '~> 6.0'

  ### s.files = Dir['Rakefile', '{bin,lib,spec}/**/*', 'README*', 'LICENSE*'] & `git ls-files -z .`.split("\0")
  s.files       = `git ls-files`.split("\n")
  s.test_files  = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
end
