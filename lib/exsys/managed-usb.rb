require "uart"

module ExSYS
class ManagedUSB
    SPEED      = 9600
    PASSWORD   = 'pass'.freeze
    PORTS      = 1.upto(16).to_a.freeze
    TRUE_LIST  = [ 1, :on,  :ON,  :true,  :TRUE,  true  ].freeze
    FALSE_LIST = [ 0, :off, :OFF, :false, :FALSE, false ].freeze
    
    class Error < StandardError
    end
    
    def initialize(line, password = nil, debug: nil)
        password ||= PASSWORD
        if password.size > 8
            raise ArgumentError, "password too long"
        end
        @line     = line
        @password = password.ljust(8)
        @debug    = debug
    end

    def toggle(*ports, commit: false)
        _set(_get ^ mask(ports, :all), commit: commit)
    end

    def on(*ports, commit: false)
        _set(_get | mask(ports, :all), commit: commit)
    end

    def off(*ports, commit: false)
        _set(_get & ~mask(ports, :all), commit: commit)
    end

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
    
    def restore
        action('RD', @password).then { self }
    end
    
    def commit
        action('WP', @password).then { self }
    end

    def reset
        action('RH', @password, reply: false).then { self }
    end

    def password(new)
        new = PASSWORD                           if new.nil?
        raise ArgumentError, 'password too long' if new.size > 8
        action('CP', @password, new.ljust(8)).then { self }
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

