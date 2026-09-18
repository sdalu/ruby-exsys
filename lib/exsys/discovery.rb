require 'open3'
require 'rbconfig'
require 'shellwords'

require_relative 'managed-usb'

module ExSYS

class ManagedUSB

    # USB vendor and product of the hub's management adapter.
    #
    # It is not an ExSYS id.  The management side of the hub is an
    # ordinary FTDI FT232, so this pair matches the hub AND every other
    # FT232 attached to the host: a USB-serial cable, a debug probe,
    # a second hub.  Nothing short of opening the line and asking it
    # (?Q, see {#query}) tells them apart, and opening an unknown line
    # means writing to somebody else's device.
    #
    # So {available} reports candidates, and choosing between them is
    # the caller's -- see the note there.
    CTRL_VENDOR  = '0403'.freeze
    CTRL_PRODUCT = '6001'.freeze

    # What a USB path looks like: a bus, a dash, and the chain of hub
    # ports leading to the device -- 1-1.2.4.4.  Published so that a
    # caller taking a device name from a human or a configuration file
    # can tell one from a serial number without inventing the pattern
    # again; the two cannot be confused, a serial never being digits
    # and dashes in this shape.
    USB_PATH = /\A\d+-\d+(?:\.\d+)*\z/

    # Every serial line on this host that could be a managed hub.
    #
    # Each entry carries the names the host knows the adapter by:
    #
    #     [ { :device   => '/dev/ttyUSB0',
    #         :serial   => 'AL03GD7X',
    #         :usb_path => '1-1.2.4.4' },
    #       { :device   => '/dev/ttyUSB1',
    #         :serial   => nil,
    #         :usb_path => '1-1.3' } ]
    #
    # `:device` is the line, as {#initialize} wants it.
    #
    # `:serial` is the FT232's own serial number, from its EEPROM, or
    # nil for a chip carrying none -- an FT232R ships with one, an
    # unprogrammed EEPROM is possible.
    #
    # `:usb_path` is where the adapter sits in the USB tree ({USB_PATH}),
    # or nil where one cannot be established.  Linux states it; FreeBSD
    # does not, and it is walked out of the sysctl tree instead (see
    # Discovery::FreeBSD.usb_path).
    #
    # The shape is the same on both and the NUMBERING is each host's
    # own: FreeBSD counts buses from 0 and Linux from 1, and neither
    # orders its controllers for the other's benefit.  A path names a
    # socket on the host that reported it, and does not travel.
    #
    # The two are stable in DIFFERENT ways, and which is wanted depends
    # on the question.  A serial follows the adapter: move the hub to
    # another socket, another port, another machine, and its serial goes
    # with it.  A USB path follows the socket: whatever is plugged in
    # there answers to it, including a replacement hub.  For naming one
    # particular hub the serial is the answer; the path is for a hub
    # with no serial to be named by, and for a bench where the socket is
    # the thing that is fixed.
    #
    # Prefer one of them over the line for anything written down.  The number in
    # /dev/ttyUSB1 is neither the hub's nor the USB device number: it is
    # the usbserial (Linux) or ucom (FreeBSD) layer's own index, and it
    # is the lowest one free when that adapter is probed.  It therefore
    # depends on what else attached first, and it is reused -- unplug
    # whatever holds ttyUSB0 and the next thing to attach takes
    # ttyUSB0.  Two hubs can swap lines across a reboot, or while the
    # machine is up.  The serial cannot move.
    #
    # ONE candidate is not proof that it is a hub, and several are not
    # a list of hubs: see {CTRL_VENDOR}.  A caller that switches ports
    # should therefore not pick one silently when there is more than
    # one -- the ports of an unrelated hub exist, accept the frames,
    # and report success.
    #
    # @return [Array<Hash>] one { :device, :serial } per FT232 found,
    #                       in whatever order the host lists them
    # @raise  [Error] if this platform has no way to look, or the tool
    #                 that does the looking is not installed
    def self.available = Discovery.available

    # Asking the host what is attached.
    #
    # Each platform answers by running the tool that already knows --
    # udevadm on Linux, sysctl on FreeBSD -- and each keeps the running
    # and the parsing apart, so that the parsing can be tested against
    # captured output on a machine with nothing plugged in.
    module Discovery                                # @!visibility private

        def self.available
            case RbConfig::CONFIG['host_os']
            when /^linux/   then Linux.available
            when /^freebsd/ then FreeBSD.available
            else raise Error, 'no hub discovery for this platform' \
                              " (#{RbConfig::CONFIG['host_os']}):" \
                              ' name the serial line instead'
            end
        end

        # An absent USB string descriptor arrives as an empty one, not
        # as nothing: udevadm prints ID_SERIAL_SHORT='' and uftdi's
        # pnpinfo sernum="".  Both mean the EEPROM carries no serial,
        # and nothing may be identified by ''.
        def self.nonempty(str)
            s = str.to_s
            s.empty? ? nil : s
        end

        # What a platform reader ran, when it is not there at all.
        # Reported rather than swallowed: an empty list would read as
        # "no hub attached", which is a different thing and a lie.
        def self.missing(tool, error)
            raise Error, "cannot look for a hub: #{tool} (#{error.message})"
        end

        # Run a reader, and hand back only what it printed.
        #
        # Open3 with the arguments given SEPARATELY, and never a
        # backtick: a backtick takes a single string, and a single
        # string with a redirection or a metacharacter in it is run by
        # /bin/sh -- which reports a missing binary ITSELF, as exit
        # 127 and no output, so Errno::ENOENT never reaches Ruby and
        # the rescue above becomes dead code.  That is exactly how
        # this once answered "no hub attached" on a host with no
        # sysctl.  Passing the arguments apart from the command runs
        # it directly: no shell, no quoting, and a missing binary
        # raises.
        #
        # stderr is dropped rather than redirected, for one message:
        # with no FTDI ever attached the uftdi driver is not loaded,
        # the oid does not exist, and sysctl says so on stderr while
        # printing nothing.  That is not an error -- it is the answer,
        # an empty list -- and a library has no business writing it to
        # the terminal.  The exit status cannot tell the two apart
        # either: sysctl exits 1 for an unknown oid, and 1 just the
        # same when only one of several is unknown.
        def self.run(tool, *args)
            out, _err, _status = Open3.capture3(tool, *args)
            out
        rescue Errno::ENOENT, Errno::EACCES => e
            self.missing(tool, e)
        end


        module Linux
            UDEVADM = '/usr/bin/udevadm'

            def self.available
                Dir['/sys/class/tty/ttyUSB*'].sort.filter_map {|path|
                    self.candidate(self.properties(path))
                }
            end

            # One candidate, or nil for an adapter that is not an FT232.
            def self.candidate(props)
                return nil unless props[:ID_VENDOR_ID] == CTRL_VENDOR &&
                                  props[:ID_MODEL_ID]  == CTRL_PRODUCT
                { :device   => props[:DEVNAME],
                  :serial   => Discovery.nonempty(props[:ID_SERIAL_SHORT]),
                  :usb_path => self.usb_path(props[:DEVPATH]) }
            end

            # The adapter's own place in the USB tree, out of the sysfs
            # path the tty hangs off.
            #
            # DEVPATH carries the whole chain -- the bus, every hub
            # between, the device, its interface, then the tty:
            #
            #     .../usb1/1-1/1-1.2/1-1.2.4/1-1.2.4.4/1-1.2.4.4:1.0/
            #         ttyUSB0/tty/ttyUSB0
            #
            # Every hub on the way matches {USB_PATH} as well, so it is
            # the LAST match that is the device itself; the interface
            # component after it carries a ':' and matches nothing.
            def self.usb_path(devpath)
                devpath.to_s.split('/').grep(USB_PATH).last
            end

            # udevadm's --export format: KEY='value' a line, the value
            # quoted the way a shell would want it.
            def self.parse(export)
                export.lines.to_h {|l| l.split('=', 2) }
                      .transform_keys(&:to_sym)
                      .transform_values {|v| Shellwords.split(v).join(' ') }
            end

            def self.properties(path)
                self.parse(Discovery.run(UDEVADM, 'info', '-q', 'property',
                                         '--export', path))
            end
        end


        module FreeBSD
            SYSCTL = '/sbin/sysctl'

            # The two branches read together, in one call: the adapters
            # themselves, and every hub, which is what the walk from an
            # adapter up to its bus passes through and nothing else.
            OIDS = %w[dev.uftdi dev.uhub].freeze

            def self.available
                tree = self.parse(self.read(*OIDS))
                tree.filter_map {|name, dev|
                    next unless name.start_with?('uftdi')
                    self.candidate(dev, tree)
                }
            end

            def self.candidate(dev, tree = {})
                pnp = dev[:'%pnpinfo']
                return nil unless pnp.is_a?(Hash)
                return nil unless pnp[:vendor]  == "0x#{CTRL_VENDOR}" &&
                                  pnp[:product] == "0x#{CTRL_PRODUCT}"
                { :device   => '/dev/tty' + dev[:ttyname].to_s,
                  :serial   => Discovery.nonempty(pnp[:sernum]),
                  :usb_path => self.usb_path(dev, tree) }
            end

            # The adapter's place in the USB tree, built by walking it.
            #
            # There is no /sys/bus/usb here and nothing states a path,
            # but every piece of one is in the sysctl tree.  A device's
            # %location gives the bus and the port it occupies on its
            # parent, and its %parent names that parent -- always a
            # uhub, up to the root hub, whose own %location is empty
            # and whose parent is the usbus.  Collecting the ports on
            # the way up and reversing them is the path:
            #
            #     uftdi0  port=4  parent=uhub5 ┐
            #     uhub5   port=4  parent=uhub4 │  1-1.1.4.4
            #     uhub4   port=1  parent=uhub2 │
            #     uhub2   port=1  parent=uhub0 ┘  (root: stop)
            #
            # The shape is Linux's, and the numbering is this host's.
            # FreeBSD counts buses from 0 and Linux from 1, and neither
            # orders its controllers for the other's benefit, so the
            # same socket is not the same string on the two systems.  A
            # path names a socket on THIS host; see {USB_PATH}.
            # A walk that does not REACH the root hub answers nil.
            # Running off the end of the tree -- a parent nothing read
            # describes -- leaves the ports collected so far, which
            # read as a whole path and are not one: stopping one hub
            # short of the root turns 1-1.1.4.4 into 1-4, a path that
            # exists, names a socket, and is the wrong one.
            def self.usb_path(dev, tree)
                bus    = nil
                ports  = []
                rooted = false
                while dev
                    loc = dev[:'%location']
                    unless loc.is_a?(Hash) && loc[:port]
                        rooted = true    # a root hub occupies no port
                        break
                    end
                    bus ||= loc[:bus]
                    ports.unshift(loc[:port])
                    dev = tree[dev[:'%parent'].to_s]
                end
                return nil unless rooted && bus && !ports.empty?
                "#{bus}-#{ports.join('.')}"
            end

            # sysctl -e output, as { "uftdi0" => { key => value } }.
            #
            # Keyed by the device's name and not by its unit number:
            # two branches are read at once, %parent names a parent
            # that way, and unit numbers repeat across drivers.
            #
            # The two keys holding a list of their own -- %pnpinfo and
            # %location -- are split into a hash of their own, since
            # what is wanted is inside them.
            def self.parse(output)
                output.lines.map(&:chomp).reduce({}) {|acc, l|
                    k, v     = l.split('=', 2)
                    next acc if k.nil?
                    dev, i, sk = k.split('.')[1..]
                    # No unit number in it -- dev.uhub.%parent -- so
                    # it describes the driver and not a device.
                    next acc if sk.nil? || i !~ /\A\d+\z/
                    if [ '%pnpinfo', '%location' ].include?(sk)
                        # Not every token in one of these is a pair:
                        # dev.acpi_timer.0.%pnpinfo is the bare word
                        # 'unknown'.  Nothing outside a USB branch is
                        # read today, but a parser that dies on one
                        # driver's wording would take the hub with it.
                        v = Shellwords.shellsplit(v.to_s)
                                      .filter_map {|e|
                                          k2, v2 = e.split('=', 2)
                                          [ k2.to_sym, v2 ] if v2
                                      }.to_h
                    end
                    acc.merge("#{dev}#{i}" => { sk.to_sym => v }) {
                        |_k, o, n| o.merge(n)
                    }
                }
            end

            def self.read(*keys)
                Discovery.run(SYSCTL, '-e', *keys)
            end
        end
    end
end

end
