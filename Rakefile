require "rake/testtask"

namespace :test do
  Rake::TestTask.new(:core) do |t|
    t.libs << "test" << "lib"
    t.test_files = FileList["test/*_test.rb"]
    t.warning = false
  end

  # Railtie tests load Rails, so they run in a separate process from the core suite.
  Rake::TestTask.new(:rails) do |t|
    t.libs << "test" << "lib"
    t.test_files = FileList["test/rails/*_test.rb"]
    t.warning = false
  end
end

desc "Run core and Rails test suites"
task test: [ "test:core", "test:rails" ]

task default: :test
