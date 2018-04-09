require 'rubygems'
require 'sinatra'
require_relative 'server'

task :default do
  Dir.foreach('artwork') do |f|
    next if f[0] == '.'
    File.delete('artwork/' + f)
  end

  Dir.foreach('waveforms') do |f|
    next if f[0] == '.'
    File.delete('waveforms/' + f)
  end

  Server.run!
end
