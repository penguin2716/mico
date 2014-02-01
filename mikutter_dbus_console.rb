#!/usr/bin/env ruby

require 'dbus'
require 'readline'
require 'pry'

session_bus = DBus::SessionBus.instance

mikutter_srv = session_bus.service("org.mikutter.dynamic")
@player = mikutter_srv.object("/org/mikutter/MyInstance")
begin
  @player.introspect
rescue
  puts "error: couldn't connect to org.mikutter.dynamic"
  exit 1
end
@player.default_iface = "org.mikutter.eval"

def mikutter_eval(ruby_code)
  result = @player.ruby([["code", ruby_code], ["file", ""]])
  if result.first =~ /^(#<Deferred:[0-9xa-f]+)/
    puts $1 + "...>"
  else
    puts result.first
  end
end

while ruby_code = Readline.readline("mikutter> ", true)
  unless ruby_code.empty?

    ruby_code =~ /^(:[a-z]+)\s*/
    first_block = $1
    args_block = ruby_code.gsub(/^(:[a-z]+)\s*/, "")

    case first_block
    when ':quit'
      break
    when ':post'
      mikutter_eval "Service.primary.post :message => \"#{args_block}\""
    else
      mikutter_eval ruby_code
    end

  end
end
