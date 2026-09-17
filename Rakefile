require 'bundler'
require 'rake/testtask'
require 'yard'

Bundler::GemHelper.install_tasks

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
