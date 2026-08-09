# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = false
end

desc "Wake the creature locally"
task :serve do
  sh "bundle exec puma -C config/puma.rb"
end

desc "Show what the creature currently is"
task :introspect do
  require_relative "app"
  App.wake!
  puts "body        #{Body.short_id} (pid #{Body.pid})"
  puts "mode        #{Body.mode}#{Body.mode_reason ? " · #{Body.mode_reason}" : ''}"
  puts "generation  #{Body.generation}"
  puts "routes      #{DynamicRoutes.active.map { |r| r['path'] }.join(', ')}"
  puts "psyche      #{Psyche.summary}"
  puts "attention   #{BudgetGuard.snapshot}"
end

task default: :test
