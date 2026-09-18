require 'bundler'
require 'rake/clean'
require 'rake/testtask'
require 'yard'

Bundler::GemHelper.install_tasks

# What a build leaves behind.
#
# CLEAN is the intermediate that is rebuilt from the sources every
# time: yard's object database.  CLOBBER adds the products themselves
# -- rendered documentation, packaged gems -- which `rake yard` and
# `rake build` put back.
#
# Every entry is a path this repository's own tasks write, and every
# one of them is in .gitignore.  Nothing is listed by a wildcard that
# could reach further than that: clobber is a delete, and a list that
# grows to match somebody's files is how a clean target eats work.
CLEAN.include('.yardoc', '_yardoc')
CLOBBER.include('doc', 'rdoc', 'pkg', 'coverage', '*.gem')

Rake::TestTask.new do |t|
    t.test_files = FileList['test/test_*.rb']
    t.verbose    = true
    t.warning    = false
end

task :default => :test

YARD::Rake::YardocTask.new do |t|
    t.files         = [ 'lib/**/*.rb', 'ext/ucl.c' ]
    t.options       = [ '-m', 'markdown' ]
    t.stats_options = [ '--list-undoc' ]
end
