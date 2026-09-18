require "uart"

module ExSYS

# Control a ExSYS Managed USB hub
#
# The hub is commanded over a serial line, not over USB.  Each command
# is a short ASCII frame closed by CR, and the hub answers G on success
# or Exx on error.  GP is the exception: it needs no password, and it
# answers the port state directly.
#
#     ?Q   describe the hub           GP   read the port state
#     SP   set it, in RAM             FP   set it, in RAM and flash
#     WP   write RAM to flash         CP   change the password
#     RD   restore factory defaults   RH   reset the hub (no reply)
#
# A frame carries the whole 16-port state, so changing one port is a
# read-modify-write: GP to read it, then SP to put it back.
#
#     ┌────┬──────────┬──────────┐
#     │ SP │ pass···· │ 0300FFFF │
#     └─┬──┴────┬─────┴────┬─────┘
#       │       │          └───────  port state, low byte first, hub's width
#       │       └──────────────────  password, 8 chars (· = pad space)
#       └──────────────────────────  command, 2 chars
#
# The fields go out concatenated, with no separator: the frame above
# is written as "SPpass    0300FFFF\r".
#
# The state word is wider than the ports the hub has.  A 16-port unit
# answers eight hex digits, four bytes, and the ports it does not have
# read as 1.  A client therefore writes back what it read rather than
# padding, because on a 32-port hub padding with FFFF is not padding
# at all: it is a command to power ports 17 to 32.
#
# Port n is bit n-1 of the state word, and the word is sent low byte
# first, so ports 1 and 2 on, on a hub whose other ports read 1,
# reaches the wire as "0300FFFF".  The low half of that:
#
#       port  8  7  6  5  4  3  2  1    16 15 14 13 12 11 10  9
#       bit   0  0  0  0  0  0  1  1     0  0  0  0  0  0  0  0
#           └───── low byte  03 ───┘   └──── high byte  00 ───┘
#
# How many ports a hub has is its own to say: ?Q reports it, and
# {#ports} is that list.
class ManagedUSB
    SPEED      = 9600                     # @!visibility private
    PASSWORD   = 'pass'.freeze            # @!visibility private
    PORTS      = 1.upto(16).to_a.freeze   # @!visibility private
    ALL        = :all                     # every port, said explicitly
    # The shapes {#get} will answer in; see it for what each one is.
    TYPES      = [ :ports, :on_off, :on, :off ].freeze
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

    # Raised when the hub refuses a command outright, as older firmware
    # does for ?Q.  Distinct from {Error} so that a refusal can be
    # worked around while a reply nobody can read still stops things.
    class Unsupported < Error
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
        @width    = 8         # until the hub says otherwise
    end

    # Toggle the given ports
    #
    # @param ports    [Integer,:all] ports to invert, or ALL for every
    #                                one.  An empty list is an error.
    # @param commit   [Boolean] Commit to flash memory
    def toggle(*ports, commit: false)
        session do
            # The mask first: it settles how many ports the hub
            # has, and validates the list, before the hub is read.
            m = mask(ports)
            _set(_get ^ m, commit: commit)
        end
    end

    # Turn on the given ports
    #
    # @param ports    [Integer,:all] ports to power, or ALL for every
    #                                one.  An empty list is an error.
    # @param commit   [Boolean] Commit to flash memory
    def on(*ports, commit: false)
        session do
            # The mask first: it settles how many ports the hub
            # has, and validates the list, before the hub is read.
            m = mask(ports)
            _set(_get | m, commit: commit)
        end
    end

    # Turn off the given ports
    #
    # @param ports    [Integer,:all] ports to unpower, or ALL for every
    #                                one.  An empty list is an error.
    # @param commit   [Boolean] Commit to flash memory
    def off(*ports, commit: false)
        session do
            # The mask first: it settles how many ports the hub
            # has, and validates the list, before the hub is read.
            m = mask(ports)
            _set(_get & ~ m, commit: commit)
        end
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
        # One session for the whole thing: normalising asks the hub how
        # many ports it has, and that answer must come from the same
        # held line as the read-modify-write it feeds.
        session do
            wanted = normalize(dataset, default)
            val    = _get

            wanted.each do |k, v|
                flg = 1 << (k-1)
                if v
                then val |=  flg
                else val &= ~flg
                end
            end

            _set(val, commit: commit)
        end
    end

    # Ask the hub to describe itself
    #
    # One of the two commands needing no password.  The reply is a
    # single string -- "CENTOS000516v02" on the 16-port model -- made
    # of an identifier, four digits, the port count, and a firmware
    # version.  It carries no port states: those come from GP.
    #
    # The count is the two digits before the firmware, which is where
    # the vendor's own tool reads it, checked against that tool for
    # hubs reporting 4, 8, 16 and 32.  The four digits before it are
    # returned in :raw and nowhere else: what they mean is not known,
    # and the vendor ignores them too.
    #
    # @return [Hash] :id, :ports, :firmware, and the :raw reply
    def query
        raw = action('?Q', check: false)
        if (raw.size == 3) && (raw[0] == 'E')
            raise Unsupported, "hub refused the query: #{raw[1..-1]}"
        end
        unless raw =~ /\A([A-Z]+)(\d*)(\d{2})(v\S*)\z/
            raise Error, "unexpected query reply: #{raw.inspect}"
        end
        { :id => $1, :ports => $3.to_i, :firmware => $4, :raw => raw }
    end

    # Number of ports the hub says it has
    #
    # Asked once, before the first operation needing it, and then
    # remembered.  This is what {ALL} covers and what a port is checked
    # against.
    #
    # @note Remembered for the life of this object, which outlasts any
    #   one connection: the line is opened per operation, not held.  So
    #   an instance is bound to the hub it first asked.  If the device
    #   is unplugged and another appears under the same name, build a
    #   new instance rather than reusing this one -- nothing here can
    #   notice the swap.
    #
    # Falls back to {PORTS}.size when the firmware is too old to answer
    # {#query}.  A reply that arrives but cannot be read raises
    # instead: guessing low there would leave a wider hub's upper ports
    # untouched while reporting success.
    #
    # @return [Integer]
    def port_count
        @port_count ||=
            begin
                n = query[:ports]
                # PS64 in the vendor's own symbols: 64 ports is the
                # most the protocol can express.
                unless n.between?(1, 64)
                    raise Error, "hub reports #{n} ports"
                end
                n
            rescue Unsupported
                # Firmware too old to be asked.  Sixteen is the only
                # safe guess: it is what the state word addresses on
                # every hub this gem has been run against.  A reply
                # that arrives but cannot be read is NOT this case and
                # is left to raise -- guessing low there would leave a
                # wider hub's upper ports untouched while reporting
                # success.
                @debug&.puts '!!! hub will not answer ?Q, assuming ' \
                             "#{PORTS.size} ports"
                PORTS.size
            end
    end

    # The ports this hub has, as a list
    #
    # From {#port_count}, so asked of the hub once and bound to this
    # object for its lifetime.
    #
    # @return [Array<Integer>]
    def ports = 1.upto(port_count).to_a

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
    # @raise [ArgumentError] for a type outside {TYPES}
    def get(type = :ports)
        # Checked before the line is opened.  An unknown type is a
        # caller's typo and nothing the hub can answer, so spending a
        # GP and a ?Q on it before saying so helps nobody.
        unless TYPES.include?(type)
            raise ArgumentError, "unknown type: #{type.inspect} " \
                                 "(expected one of #{TYPES.inspect})"
        end

        h = session do
            v = _get
            ports.reduce({}) {|acc, obj|
                acc.merge(obj => (v & (1 << (obj-1))).positive?)
            }
        end

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
            # Unreachable: TYPES is checked on the way in.  Here so
            # that a type added to that list and not to this case says
            # so, rather than answering nil.
            raise Error, "no reader for #{type.inspect}"
        end
    end

    # Restore the hub to its factory defaults
    #
    # Refuses without +confirm: true+.  This is the one operation here
    # that cannot be undone, and the one a caller is most likely to
    # reach by misunderstanding, so it asks to be meant.
    #
    # @note This is destructive, and is not the inverse of {#commit}:
    #   it drops every port and resets the password.  Nothing in the
    #   protocol reloads the flashed state -- the hub applies it at
    #   power-on by itself.  Confirmed against the vendor's own cusba
    #   tool, whose /D issues the same RD command and documents it as
    #   "restore to factory default settings".
    # @note The password this object holds follows the hub's back to
    #   {PASSWORD}, so it stays usable afterwards.
    # @param confirm [Boolean] must be true; the keyword is the point
    # @raise [ArgumentError] when not confirmed
    def factory_reset(confirm: false)
        unless confirm
            raise ArgumentError,
                  'factory_reset drops every port and resets the ' \
                  'password, and nothing undoes it; pass confirm: true'
        end
        action('RD', @password, secrets: [ @password ])
        # RD puts the hub's password back to the default, so the one
        # this object was holding is now the wrong one.  Forgetting it
        # here is what keeps the NEXT command from being refused by a
        # hub that did exactly what it was told: without this, every
        # later call on a hub that had a password raises E01, and
        # nothing on the wire says why.
        @password = PASSWORD.ljust(8)
        self
    end

    # @deprecated Renamed to {#factory_reset} in 1.0.
    #
    # The old name read as the inverse of {#commit}, which it never
    # was, so it is gone rather than aliased -- a caller holding that
    # belief needs to be stopped, not quietly forwarded.
    def restore
        raise NoMethodError,
              'restore was renamed factory_reset: RD restores the hub ' \
              'to factory defaults, dropping every port and resetting ' \
              'the password.  It is not the inverse of commit.'
    end

    # Save the port states to the flash memory
    def commit
        action('WP', @password, secrets: [ @password ]).then { self }
    end

    # Perform a hub reset action
    #
    # Refuses without +confirm: true+, for the same reason
    # {#factory_reset} does: every port loses power while it runs.
    #
    # @note power is not maintained accros a reset
    # @param confirm [Boolean] must be true; the keyword is the point
    # @raise [ArgumentError] when not confirmed
    def reset(confirm: false)
        unless confirm
            raise ArgumentError,
                  'reset reboots the hub, and every port loses power ' \
                  'while it does; pass confirm: true'
        end
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

    # Turn either accepted port-state notation into { port => bool },
    # with the unlisted ports filled in when a default is given and
    # dropped when it is not.
    def normalize(dataset, default)
        keys = dataset.keys
        if (keys - ports).empty?
            # to_h rather than transform_values, so that a value that
            # is not a state can name the port it was given for: with
            # sixteen of them, the offending value alone is not enough
            # to find the typo by.
            dataset = dataset.to_h do |k, v|
                [ k, case v
                     when * TRUE_LIST then true
                     when *FALSE_LIST then false
                     when nil
                     else raise ArgumentError,
                                "not a port state: #{k} => #{v.inspect}"
                     end ]
            end
        elsif (keys - [:on, :off]).empty?
            on  = Array(dataset[:on ])
            off = Array(dataset[:off])

            check_ports(on + off)

            unless (on & off).empty?
                raise ArgumentError, "on/off overlap"
            end

            dataset = on .to_h {|k| [k, true  ] }
                        .merge(off.to_h {|k| [k, false ] })
        else
            raise ArgumentError,
                  'dataset is neither { port => state } nor ' \
                  "{ :on/:off => ports }: #{keys.inspect}"
        end

        unless default.nil?
            (ports - dataset.keys).each {|k| dataset[k] = default }
        end

        dataset.compact
    end

    def check_ports(list)
        known = ports
        list.each do |p|
            unless known.include?(p)
                raise ArgumentError, "invalid port: #{p.inspect}"
            end
        end
    end
    
    def mask(list)
        # An empty list is refused rather than taken to mean everything.
        # A caller splatting a computed list cannot say "none": on(*[])
        # and on() are the same call, so the convenience would silently
        # switch every port whenever the list came back empty.
        if list.empty?
            raise ArgumentError,
                  "no port given (#{ALL.inspect} means every port)"
        end
        list = ports if list == [ ALL ]

        check_ports(list)
        list.reduce(0) {|acc, obj| acc | (1 << (obj-1)) }
    end

    def _get
        data = action('GP', check: false)

        if (data.size == 3) && (data[0] == 'E')
            raise Error, data[1..-1]
        elsif data.empty? || !data.match?(/\A(?:\h\h)+\z/)
            raise Error, "unexpected reply: #{data.inspect}"
        end

        # The hub sets the width, and keeps it: a 16-port model answers
        # eight hex digits, four bytes, of which only the low sixteen
        # bits are ports it has.  Whatever comes back is written back.
        @width = data.size
        decode(data)
    end

    # Little-endian byte order, any width.
    def decode(hex)
        hex.scan(/\h\h/).each_with_index
           .sum {|byte, i| byte.to_i(16) << (8 * i) }
    end

    def encode(v, width)
        (width / 2).times.map {|i| format('%02X', (v >> (8 * i)) & 0xff) }
                   .join
    end

    # Always preceded by a {#_get} in the same session, which is what
    # fixes the width and carries the bits above the hub's real ports
    # back untouched.  Those bits read as 1 on a hub that has fewer
    # ports than its word is wide; writing them back as read is what
    # keeps a wider hub from having its upper ports driven.
    def _set(v, commit: false)
        if (v >> (@width * 4)).positive?
            raise Error, "hub reports #{port_count} ports but answers a " \
                         "#{@width * 4}-bit state word"
        end
        action(commit ? 'FP' : 'SP', @password, encode(v, @width),
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
                # To the line terminator, not to EOF.  There is no EOF
                # on a serial line: what ends a read is the uart gem's
                # VTIME, half a second of silence, so reading to EOF
                # spent that half second on every single command while
                # the hub had already answered.  A hub that says
                # nothing still costs exactly that, and still yields
                # the empty string the callers below expect.
                (serial.gets("\n") || '').chomp.tap do |data|
                    @debug&.puts "--> #{data}"
                    if check && data[0] != 'G'
                        # Exx is the hub saying no, and xx is what it
                        # said.  Anything else is NOT a code, and must
                        # not be reported as one: data[1..-1] of ''
                        # -- which is what a silent hub and a timed-out
                        # read both look like -- is nil, and an Error
                        # raised with nil carries the class name as its
                        # message and nothing else.  Of a one-character
                        # reply it is '', an error with no message at
                        # all.  Either way the operator is told the
                        # command failed and not one thing more, at
                        # exactly the moment the line went quiet.
                        code = data.match(/\AE(\S+)\z/)
                        raise Error, code ? code[1]
                                     : "unexpected reply: #{data.inspect}"
                    end
                end
            end
        end
    end
end
end

