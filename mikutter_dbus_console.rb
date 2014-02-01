#!/usr/bin/env ruby
# -*- coding: utf-8 -*-

require 'dbus'
require 'readline'
require 'socket'
require 'pry'

@locks = Queue.new

Thread.new do
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

  def mikutter_deferred_callback(code, method)
    ruby_code =<<EOF
ret = ( #{code} )
if ret.instance_of? Deferred
ret.next{ |result|
  sock = TCPSocket.open('localhost', 23456)
  sock.p result #{method}
  sock.close
}
end
EOF
    @player.ruby([["code", ruby_code], ["file", ""]])
  end

  def mikutter_deferred_inspect(object_id)
    ruby_code = "ObjectSpace.each_object(Deferred).to_a.select{|d| d.object_id == #{object_id}}.first.next{|result| Plugin.call(:update, nil, [Message.new(message: result.inspect, system: true)])}"
    @player.ruby([["code", ruby_code], ["file", ""]])
  end

  def mikutter_eval(ruby_code)
    result = @player.ruby([["code", ruby_code], ["file", ""]])
    if result.first =~ /^#<Deferred:([0-9xa-f]+)/
      puts "#<Deferred:#{$1}...>"
      #mikutter_deferred_inspect ((eval $1) >> 1)
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
        @locks.push :lock
      else

        if ruby_code =~ /^\$\(\(([\s\S]+)\)\)([\s\S]+)?/
          code = $1
          method = $2
          mikutter_deferred_callback code, method
          @locks.pop
          @locks.push :lock
        else
          mikutter_eval ruby_code
          @locks.push :lock
        end

      end

    else
      @locks.push :lock
    end

    @locks.pop
  end

end

Signal.trap(:INT){
  puts "exit"
  s = TCPSocket.open('localhost', 23456)
  s.puts ":exit"
  s.close
}

TCPServer.open('localhost', 23456) do |serv|
  loop do
    client = nil
    client = serv.accept
    buf = client.read
    break if buf.chomp == ':exit'
    puts buf
    client.close
    @locks.push :lock
  end
end
