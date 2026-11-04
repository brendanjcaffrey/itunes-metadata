require 'rubygems'
require 'sinatra'
require_relative 'server'

task :default do
  Server.run!
end

task :test do
  ruby '-Itest', '-e', 'Dir["test/*_test.rb"].sort.each { |file| require_relative file }'
end
