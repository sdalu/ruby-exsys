# Test double for the `uart` gem.
#
# test/helper.rb puts this directory on the load path ahead of the real
# gem, so `require "uart"` inside ExSYS::ManagedUSB picks this up and
# the suite runs against FakeHub.  That is what lets the tests run with
# no hub attached and with neither the uart nor the termios gem
# installed.
require_relative 'fake_hub'

module UART
    class << self
        attr_writer :hub

        # In-process tests set the hub directly; the subprocesses the
        # executable's tests spawn build theirs from the environment.
        def hub = @hub ||= FakeHub.from_env

        def reset! = @hub = nil
    end

    # Stands in for the File that UART.open normally yields.
    class Serial
        def initialize(hub) = @hub = hub
        def flock(mode)     = @hub.flock(mode)
        def write(cmd)      = @reply = @hub.command(cmd.chomp("\r"))
        def read            = @reply.nil? ? '' : "#{@reply}\r"
    end

    def self.open(line, speed = 9600, mode = '8N1')
        hub.opened(line, speed, mode)
        serial = Serial.new(hub)
        return serial unless block_given?

        begin
            yield serial
        ensure
            hub.unlock
        end
    end
end
