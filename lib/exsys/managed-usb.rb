require "uart"

module ExSYS

# Control a ExSYS Managed USB hub
#
# The hub is commanded over a serial line, not over USB.  Each command
# is a short ASCII frame closed by CR, and the hub answers G on success
# or Exx on error.  GP is the exception: it needs no password, and it
# answers the port state directly.
#
#     GP   read the port state      SP   set it, in RAM
#     WP   write RAM to flash       FP   set it, in RAM and flash
#     RD   restore RAM from flash   CP   change the password
#     RH   reset the hub (no reply)
#
# A frame carries the whole 16-port state, so changing one port is a
# read-modify-write: GP to read it, then SP to put it back.
#
#     ┌────┬──────────┬──────┬──────┐
#     │ SP │ pass···· │ 0300 │ FFFF │
#     └─┬──┴────┬─────┴──┬───┴──┬───┘
#       │       │        │      └─────  port mask, 4 hex, always FFFF
#       │       │        └────────────  port state, 4 hex, low byte first
#       │       └─────────────────────  password, 8 chars (· = pad space)
#       └─────────────────────────────  command, 2 chars
#
# The fields go out concatenated, with no separator: the frame above
# is written as "SPpass    0300FFFF\r".
#
# Port n is bit n-1 of the state word, and the word is sent low byte
# first, so ports 1 and 2 on is 0x0003 and reaches the wire as "0300":
#
#       port  8  7  6  5  4  3  2  1    16 15 14 13 12 11 10  9
#       bit   0  0  0  0  0  0  1  1     0  0  0  0  0  0  0  0
#           └───── low byte  03 ───┘   └──── high byte  00 ───┘
#
# The mask selects which ports the state word applies to; the library
# always sends FFFF, i.e. all sixteen.
class ManagedUSB
    SPEED      = 9600                     # @!visibility private
    PASSWORD   = 'pass'.freeze            # @!visibility private
    PORTS      = 1.upto(16).to_a.freeze   # @!visibility private
    ALL        = :all                     # every port, said explicitly
    TRUE_LIST  = [ 1, :on,  :ON,  :true,  :TRUE,  :t, :T, true  ].freeze # @!visibility private
    FALSE_LIST = [ 0, :off, :OFF, :false, :FALSE, :f, :F, false ].freeze # @!visibility private

    # Raised by #flock when the platform won't lock a character device
    # Key under which each thread keeps its open lines, one per hub.
    # `private` does not apply to constants, so it lives here with the
    # rest rather than pretending to be scoped.
    SESSIONS = :exsys_managed_usb_sessions   # @!visibility private

    # Only the errors that mean "this platform will not lock this kind
    # of file".  A bad descriptor or a bad operation is a bug here, and
    # swallowing it would run unlocked while reporting success -- the
    # very outcome the lock exists to prevent -- so those propagate.
    LOCK_ERRORS = [ Errno::EOPNOTSUPP, Errno::ENOTSUP, Errno::ENOLCK,
                    NotImplementedError ].freeze # @!visibility private

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

    # Toggle the given ports
    #
    # @param ports    [Integer,:all] ports to invert, or ALL for every
    #                                one.  An empty list is an error.
    # @param commit   [Boolean] Commit to flash memory
    def toggle(*ports, commit: false)
        session { _set(_get ^ mask(ports), commit: commit) }
    end

    # Turn on the given ports
    #
    # @param ports    [Integer,:all] ports to power, or ALL for every
    #                                one.  An empty list is an error.
    # @param commit   [Boolean] Commit to flash memory
    def on(*ports, commit: false)
        session { _set(_get | mask(ports), commit: commit) }
    end

    # Turn off the given ports
    #
    # @param ports    [Integer,:all] ports to unpower, or ALL for every
    #                                one.  An empty list is an error.
    # @param commit   [Boolean] Commit to flash memory
    def off(*ports, commit: false)
        session { _set(_get & ~mask(ports), commit: commit) }
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

            check_ports(on + off)

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

        # Compute value and apply, holding the line for the whole
        # read-modify-write so a concurrent process cannot interleave
        # its own update between the read and the write.
        session do
            val = _get

            dataset.compact.each do |k,v|
                flg = 1 << (k-1)
                if v
                then val |=  flg
                else val &= ~flg
                end
            end

            _set(val, commit: commit)
        end
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
            # Seeded with both keys, so that a hub with all its ports
            # in the same state still answers the documented shape
            # instead of omitting the empty one.
            h.reduce({ :on => [], :off => [] }) {|acc, (k,v)|
                acc.merge(v ? :on : :off => [ k ]) {|_,o,n| o + n  }
            }
        when :on
            h.select {|_,v| v }.keys
        when :off
            h.reject {|_,v| v }.keys
        else
            raise ArgumentError
        end
    end

    # Restore port states from the flash memory
    def restore
        action('RD', @password, secrets: [ @password ]).then { self }
    end

    # Save the port states to the flash memory
    def commit
        action('WP', @password, secrets: [ @password ]).then { self }
    end

    # Perform a hub reset action
    #
    # @note power is not maintained accros a reset
    def reset
        action('RH', @password,
               reply: false, secrets: [ @password ]).then { self }
    end

    # Change the hub protection password
    def password(new)
        new = PASSWORD                           if new.nil?
        raise ArgumentError, 'password too long' if new.size > 8
        new_password = new.ljust(8)
        action('CP', @password, new_password,
               secrets: [ @password, new_password ])
        @password = new_password
        self
    end
    
    # Hold the serial line, exclusively locked, for the whole block.
    #
    # Every switching method already does this around its own
    # read-modify-write.  Wrapping several calls in one session extends
    # that to the sequence, which is what a read-decide-write needs if
    # another process or thread is driving the same hub:
    #
    #     hub.session do
    #         hub.off(*hub.get(:on))
    #     end
    #
    # Sessions nest: an inner one reuses the line the outer one holds,
    # so the methods above stay correct when called inside one.
    #
    # A session belongs to the thread that opened it.  Another thread
    # opens, and locks, its own rather than borrowing this one.
    #
    # @yieldparam hub [ManagedUSB] this hub
    # @return the value of the block
    def session
        return yield self if serial

        UART.open @line, SPEED do |line|
            flock(line)
            begin
                self.serial = line
                yield self
            ensure
                self.serial = nil
            end
        end
    end

    private

    # The line this thread currently holds for this hub, if any.
    #
    # Scoped to the thread as well as to the hub, because the handle and
    # its lock belong to whoever opened them: a second thread reusing
    # this one would be writing down a line it holds no lock on.
    def serial = (Thread.current[SESSIONS] ||= {})[self]

    def serial=(line)
        store = (Thread.current[SESSIONS] ||= {})
        line.nil? ? store.delete(self) : store[self] = line
    end

    def check_ports(ports)
        ports.each do |p|
            unless PORTS.include?(p)
                raise ArgumentError, "invalid port: #{p.inspect}"
            end
        end
    end
    
    def mask(ports)
        # An empty list is refused rather than taken to mean everything.
        # A caller splatting a computed list cannot say "none": on(*[])
        # and on() are the same call, so the convenience would silently
        # switch all sixteen whenever the list came back empty.
        if ports.empty?
            raise ArgumentError,
                  "no port given (#{ALL.inspect} means every port)"
        end
        ports = PORTS if ports == [ ALL ]

        check_ports(ports)
        ports.reduce(0) {|acc, obj| acc | (1 << (obj-1)) }
    end

    def _get
        data = action('GP', check: false)

        if (data.size == 3) && (data[0] == 'E')
            raise Error, data[1..-1]
        elsif data.size != 8
            raise Error, "unexpected reply: #{data.inspect}"
        end

        [ data ].pack('H4').unpack1('v')
    end

    def _set(v, commit: false)
        dataset = ([v].pack('v').unpack1('H*') + 'ffff').upcase
        action(commit ? 'FP' : 'SP', @password, dataset,
               secrets: [ @password ]).then { self }
    end

    # Take an exclusive lock on the serial line, keeping concurrent
    # processes from interleaving their own read-modify-write.
    #
    # Not every platform locks a character device; where it is refused
    # the operation carries on unlocked -- single-process use is
    # unaffected, concurrent use stays racy -- and says so on the debug
    # output rather than failing outright.
    def flock(serial)
        serial.flock(File::LOCK_EX)
    rescue *LOCK_ERRORS => e
        @debug&.puts "!!! serial line not lockable (#{e.class})"
    end

    # Blank out the passwords before a command reaches the debug output.
    def redact(str, secrets)
        secrets.reduce(str) {|acc, s| acc.gsub(s, '*' * s.size) }
    end

    def action(*cmds, reply: true, check: true, secrets: [])
        cmd = cmds.join
        session do
            @debug&.puts "<-- #{redact(cmd, secrets)}"
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

