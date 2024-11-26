# -*- encoding: utf-8 -*-

require_relative 'lib/exsys/version'

Gem::Specification.new do |s|
    s.name        = 'exsys'
    s.version     = ExSYS::VERSION
    s.summary     = "ExSYS managed USB hub support"
    s.description =  <<~EOF
      
      Provide command support to control ExSYS Managed USB hub.

      EOF

    s.homepage    = 'https://github.com/sdalu/ruby-exsys'
    s.license     = 'MIT'

    s.authors     = [ "Stéphane D'Alu" ]
    s.email       = [ 'stephane.dalu@insa-lyon.fr' ]

    s.files       = %w[ README.md exsys.gemspec ] +
                    Dir['lib/**/*.rb']

    s.bindir      = 'bin'
    s.executables << 'exsys-usb'

    s.add_dependency 'uart'
    s.add_development_dependency 'yard', '~>0'
    s.add_development_dependency 'rake', '~>13'
end
