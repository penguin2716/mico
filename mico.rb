#!/usr/bin/env ruby
# -*- coding: utf-8 -*-

=begin
mikutter console
 
Copyright (c) 2014 Takuma Nakajima
 
This software is released under the MIT License.
http://opensource.org/licenses/mit-license.php
=end

require 'dbus'
require 'readline'
require 'socket'
require 'pry'

if ARGV.size > 0
  FILE_INPUT_MODE = true
else
  FILE_INPUT_MODE = false
end

# 巫女みくさん
PORT = 35393
LESS_LINE_THRESH = 18

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

  def gets_code
    if FILE_INPUT_MODE
      ARGF.gets
    else
      ruby_code = Readline.readline("mikutter> ", true)
      Readline::HISTORY.pop if /^\s*$/ =~ ruby_code
      begin
        if Readline::HISTORY[Readline::HISTORY.length-2] == buf
          Readline::HISTORY.pop
        end
      rescue
      end
      ruby_code
    end
  end

  def mikutter_deferred_callback(code, method)
    ruby_code =<<EOF
ret = ( #{code} )
if ret.instance_of? Deferred
  ret.next{ |result|
    output = eval ""
    sock = TCPSocket.open("localhost", #{PORT})
    sock.puts (result#{method}).inspect
    sock.close
  }.trap{ |e|
    sock = TCPSocket.open('localhost', #{PORT})
    sock.puts e.inspect
    sock.close
  }
end
EOF
    @player.ruby([["code", ruby_code], ["file", ""]])
  end

  def mikutter_deferred_inspect(object_id)
    ruby_code =<<EOF
ObjectSpace.each_object(Deferred).to_a.select{ |deferred|
  deferred.object_id == #{object_id}
}.first.next{ |result|
  sock = TCPSocket.open('localhost', #{PORT})
  sock.puts true
  sock.close
}.trap{ |e|
  sock = TCPSocket.open('localhost', #{PORT})
  sock.puts e.inspect
  sock.close
}
EOF
    @player.ruby([["code", ruby_code], ["file", ""]])
  end

  def mikutter_eval(ruby_code)
    result = @player.ruby([["code", ruby_code], ["file", ""]])
    if result.first =~ /^#<(Deferred|Delayer):([0-9xa-f]+)/
      puts "=> " + colorize("#<#{$1}:#{$2}...>")
      mikutter_deferred_inspect ((eval $1) >> 1) if result.first =~ /^#<Deferred:([0-9xa-f]+)/
    else

      if (result.first.split("\n").size > LESS_LINE_THRESH) or (result.first.size > LESS_LINE_THRESH * 80)
        system "echo '=> #{colorize(result.first)}' | less -R"
      else
        puts "=> #{colorize(result.first)}"
      end
      @locks.push :lock

    end
  end

  def colorize(str)
    str.chomp!
    if str =~ /(#<[A-Z][a-zA-Z:0-9]+)/
      str.gsub(/(#<[A-Z][_a-zA-Z:0-9\. '`=>\(\)\/\+\-]+)/, "\e[32m\\1\e[0m").
        gsub(/(>|m)(:[_a-zA-Z0-9!?<=>~]+)/, "\\1\e[32;1m\\2\e[0m").
        gsub(/(=>$)/, "\e[0m\\1\e[0m").
        gsub(/(=>[^\e :])/, "\e[0m\\1\e[0m").
        gsub(/"(((\\")?[^"]?)+)"/, "\e[32m\"\\1\"\e[0m").gsub(/(\\[a-z"])/i, "\e[36;1m\\1\e[0m\e[32m").
        gsub(/(@[a-zA-Z0-9_]+)/, "\e[34;1m\\1\e[0m")
    elsif str =~ /^\[[\s\S]+\]$/
      str.gsub(/([A-Z][a-zA-Z_:]+)\(([^)]+)\)/, "\e[34;1;4m\\1\e[0m(\\2)" ).
        gsub(/(:[_a-zA-Z0-9!?<=>~]+)/, "\e[32;1m\\1\e[0m")
    elsif str =~ /^[A-Z][a-z]+$/
      "\e[34;1;4m" + str + "\e[0m"
    elsif str =~ /"(((\\")?[^"]?)+)"/
      str.gsub(/"(((\\")?[^"]?)+)"/, "\e[32m\"\\1\"\e[0m").gsub(/(\\[a-z"])/i, "\e[36;1m\\1\e[0m\e[32m")
    elsif str =~ /^#<[\s\S]+>$/
      "\e[32m" + str + "\e[0m"
    elsif str =~ /^nil|true|false$/
      "\e[36;1m" + str + "\e[0m"
    elsif str =~ /(:[_a-zA-Z0-9!?<=>~]+)/
      str.gsub(/(:[_a-zA-Z0-9!?<=>~]+)/, "\e[32;1m\\1\e[0m")
    elsif str =~ /^\d+(\.\d+)?$/
      "\e[34;1m" + str + "\e[0m"
    else
      str
    end
  end

  puts <<EOF
** Welcome to mikutter console **
Ctrl+C to exit.

EOF

  while ruby_code = gets_code

    unless ruby_code.empty? or ruby_code =~ /^\s*$/ or ruby_code =~ /^#/
      ruby_code =~ /^([a-z]+)\s*/
      first_block = $1
      args_block = ruby_code.gsub(/^([a-z]+)\s*/, "")

      case first_block
      when 'exit'
        exit
      when 'post'
        mikutter_eval "Service.primary.post :message => \"#{args_block}\""
      else

        if ruby_code =~ /^\./
          puts `#{ruby_code[1..-1]}`
          @locks.push :lock
        elsif ruby_code =~ /^\$\(\(([\s\S]+)\)\)([\s\S]+)?/
          code = $1
          method = $2
          mikutter_deferred_callback code, method
          @locks.pop
          @locks.push :lock
        else
          mikutter_eval ruby_code
        end

      end

    else
      @locks.push :lock
    end

    @locks.pop
  end
  puts 'exit'
  exit
end

Signal.trap(:INT){
  puts "exit"
  s = TCPSocket.open('localhost', PORT)
  s.puts "exit"
  s.close
}

TCPServer.open('localhost', PORT) do |serv|
  loop do
    client = nil
    client = serv.accept
    buf = client.read
    client.close
    break if buf.chomp == 'exit'

    if (buf.split("\n").size > LESS_LINE_THRESH) or (buf.size > LESS_LINE_THRESH * 80)
      system "echo '=> #{colorize(buf)}' | less -R"
    else
      puts "=> #{colorize(buf)}"
    end

    @locks.push :lock
  end
end
