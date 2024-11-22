require "uart"

module ExSYS

# Control a ExSYS Managed USB hub
class ManagedUSB
    SPEED      = 9600                     # @!visibility private
    PASSWORD   = 'pass'.freeze            # @!visibility private
    PORTS      = 1.upto(16).to_a.freeze   # @!visibility private
    TRUE_LIST  = [ 1, :on,  :ON,  :true,  :TRUE,  true  ].freeze # @!visibility private
    FALSE_LIST = [ 0, :off, :OFF, :false, :FALSE, false ].freeze # @!visibility private
    
    # Error handling class
    class Error < StandardError
    end

    # Initialize object.
    #
    # @param line     [String]  Serial line
    #                            (usually /dev/ttyU? or /dev/ttyUSB?)
    # @param password [String]  Hub password
    # @param debug    [IO]      Write debug output
    def initialize(line, password = nil, debug: nil)
        password ||= PASSWORD
        if password.size > 8
            raise ArgumentError, "password too long"
        end
        @line     = line
        @password = password.ljust(8)
        @debug    = debug
    end

    # Toggle all or specified ports
    #
    # @param commit   [Boolean] Commit to flash memory
    def toggle(*ports, commit: false)
        _set(_get ^ mask(ports, :all), commit: commit)
    end

    # Turn on all or specified ports
    # 
    # @param commit   [Boolean] Commit to flash memory
    def on(*ports, commit: false)
        _set(_get | mask(ports, :all), commit: commit)
    end

    # Turn off all or specified ports
    # 
    # @param commit   [Boolean] Commit to flash memory
    def off(*ports, commit: false)
        _set(_get & ~mask(ports, :all), commit: commit)
    end

    # Set state for the specified ports
    #
    # Port specification can have one of the folling format
    #
    # 1. hash of port values: { 1 => :on, 2 => :off, ...}
    # 2. hash of port states: { :on => [1, 3], :off => 4 }
    #
    # In the case 1. the state values can be specified by
    # 
    # * True:  1, :on,  :ON,  :true,  :TRUE,  true 
    # * False: 0, :off, :OFF, :false, :FALSE, false
    #
    # The port states that are not specified will acquire the
    # value specified by the default parameter (nil being the
    # hub port current value)
    #
    # @param dataset  [Hash]        Port state specification
    # @param default  [Boolean,nil] Default value to use if unspecified
    # @param commit   [Boolean]     Commit to flash memory
    def set(dataset, default = nil, commit: false)
        val = _get

        # Normalize
        keys = dataset.keys        
        if (keys - PORTS).empty?
            dataset = dataset.transform_values do |v|
                case v
                when * TRUE_LIST then true
                when *FALSE_LIST then false
                when nil
                else raise ArgumentError
                end
            end
        elsif (keys - [:on, :off]).empty?
            on  = Array(dataset[:on ])
            off = Array(dataset[:off])
            
            unless (on & off).empty?
                raise ArgumentError, "on/off overlap"
            end
            
            dataset = {}
            dataset.merge!(on .to_h {|k| [k, true  ] })
            dataset.merge!(off.to_h {|k| [k, false ] })
        else
            raise ArgumentError
        end

        # Fill unspecified
        unless default.nil?
            (PORTS - dataset.keys).each do |k|
                dataset.merge!(k => default)
            end
        end

        # Compute value
        dataset.compact.each do |k,v|
            flg = 1 << (k-1)
            if v
            then val |=  flg
            else val &= ~flg
            end
        end
        
        _set(val, commit: commit)
    end

    # Get hub current state for all ports
    #
    # Return value depend of the asked type (default: ports)
    #
    # * ports : { 1 => true, 2 => false, ...}
    # * on_off: { :on => [1,2,3,...], :off => [6,7,...] }
    # * on    : [ 1, 2, 3, ... ]
    # * off   : [ 1, 2, 3, ... ]
    #
    # @param type [:ports, :on_off, :on, :off] Type of returned value
    def get(type = :ports)
        val = _get
        h   = PORTS.reduce({}) {|acc, obj|
             acc.merge(obj => (val & (1 << (obj-1))).positive?)
        }

        case type
        when :ports
            h
        when :on_off
            h.reduce({}) {|acc, (k,v)|
                acc.merge(v ? :on : :off => [ k ]) {|k,o,n| o + n  }
            }
        when :on
            h.select {|k,v| v }.keys
        when :off
            h.reject {|k,v| v }.keys
        else
            raise ArgumentError
        end
    end

    # Restore port states from the flash memory
    def restore
        action('RD', @password).then { self }
    end

    # Save the port states to the flash memory
    def commit
        action('WP', @password).then { self }
    end

    # Perform a hub reset action
    #
    # @note power is not maintained accros a reset
    def reset
        action('RH', @password, reply: false).then { self }
    end

    # Change the hub protection password
    def password(new)
        new = PASSWORD                           if new.nil?
        raise ArgumentError, 'password too long' if new.size > 8
        new_password = new.ljust(8)
        action('CP', @password, new_password)
        @password = new_password
        self
    end
    
    private
    
    def mask(ports, empty = :none)
        case empty
        when :none
        when :all
            ports = PORTS if ports.empty?
        else raise ArgumentError
        end
        
        ports.reduce(0) {|acc, obj| acc |= 1 << (obj-1) }
    end

    def _get
        data = action('GP', check: false)

        if (data.size == 3) && (data[0] == 'E')
            raise Error, data[1..-1]
        elsif data.size != 8
            raise Error
        end

        [ data ].pack('H4').unpack1('v')
    end

    def _set(v, commit: false)
        dataset = ([v].pack('v').unpack1('H*') + 'ffff').upcase
        action(commit ? 'FP' : 'SP', @password, dataset).then { self }
    end
    
    
    def action(*cmds, reply: true, check: true)
        cmd = cmds.join
        UART.open @line, SPEED do |serial|
            @debug&.puts "<-- #{cmd}"
            serial.write "#{cmd}\r"
            if reply
                serial.read.chomp.tap do |data|
                    @debug&.puts "--> #{data}"
                    if check && data[0] != 'G'
                        raise Error, data[1..-1]
                    end
                end
            end
        end
    end
end
end

