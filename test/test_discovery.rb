require_relative 'helper'

# Finding the hub's serial line, per platform.
#
# The reading and the parsing are kept apart in Discovery precisely so
# that this runs on a machine with nothing attached: what is asserted
# here is the parsing, against the output the two tools produce, and
# not that this host has a hub on it.
class TestDiscovery < Minitest::Test
    D = ExSYS::ManagedUSB::Discovery

    # sysctl -e dev.uftdi dev.uhub.
    #
    # The uhub half is captured verbatim from a real FreeBSD host --
    # two controllers, a Genesys hub on one and a chain of two TI hubs
    # on the other -- because the walk that builds a USB path out of it
    # is the part worth testing against something nobody invented.
    #
    # The uftdi half is written: three adapters, one hanging off the
    # deepest hub, one whose EEPROM carries no serial, and an FT230X,
    # which uftdi drives too and which is not what is wanted.
    UHUB = <<~'SYSCTL'
        dev.uhub.%parent=
        dev.uhub.0.%location=
        dev.uhub.0.%parent=usbus1
        dev.uhub.1.%location=
        dev.uhub.1.%parent=usbus0
        dev.uhub.2.%location=bus=1 hubaddr=1 port=1 devaddr=3 interface=0 ugen=ugen1.3
        dev.uhub.2.%parent=uhub0
        dev.uhub.3.%location=bus=0 hubaddr=1 port=2 devaddr=2 interface=0 ugen=ugen0.2
        dev.uhub.3.%parent=uhub1
        dev.uhub.4.%location=bus=1 hubaddr=3 port=1 devaddr=4 interface=0 ugen=ugen1.4
        dev.uhub.4.%parent=uhub2
        dev.uhub.5.%location=bus=1 hubaddr=4 port=4 devaddr=5 interface=0 ugen=ugen1.5
        dev.uhub.5.%parent=uhub4
    SYSCTL

    UFTDI = <<~'SYSCTL'
        dev.uftdi.0.%desc=FTDI FT232R USB UART
        dev.uftdi.0.%driver=uftdi
        dev.uftdi.0.%location=bus=1 hubaddr=5 port=4 devaddr=9 interface=0 ugen=ugen1.9
        dev.uftdi.0.%pnpinfo=vendor=0x0403 product=0x6001 devclass=0x00 devsubclass=0x00 devproto=0x00 sernum="AL03GD7X" release=0x0600 mode=host intclass=0xff intsubclass=0xff intprotocol=0xff
        dev.uftdi.0.%parent=uhub5
        dev.uftdi.0.ttyname=U0
        dev.uftdi.0.ttyports=1
        dev.uftdi.1.%desc=FTDI FT232R USB UART
        dev.uftdi.1.%driver=uftdi
        dev.uftdi.1.%location=bus=0 hubaddr=2 port=3 devaddr=7 interface=0 ugen=ugen0.7
        dev.uftdi.1.%pnpinfo=vendor=0x0403 product=0x6001 devclass=0x00 devsubclass=0x00 devproto=0x00 sernum="" release=0x0600 mode=host intclass=0xff intsubclass=0xff intprotocol=0xff
        dev.uftdi.1.%parent=uhub3
        dev.uftdi.1.ttyname=U1
        dev.uftdi.1.ttyports=1
        dev.uftdi.2.%desc=FTDI FT230X Basic UART
        dev.uftdi.2.%driver=uftdi
        dev.uftdi.2.%pnpinfo=vendor=0x0403 product=0x6015 devclass=0x00 devsubclass=0x00 devproto=0x00 sernum="DT04H6789" release=0x1000 mode=host intclass=0xff intsubclass=0xff intprotocol=0xff
        dev.uftdi.2.%parent=uhub3
        dev.uftdi.2.ttyname=U2
        dev.uftdi.2.ttyports=1
    SYSCTL

    # udevadm info -q property --export, for one FT232R.
    UDEVADM = <<~'UDEV'
        DEVNAME='/dev/ttyUSB0'
        DEVPATH='/devices/pci0000:00/0000:00:14.0/usb1/1-1/1-1.2/1-1.2.4/1-1.2.4.4/1-1.2.4.4:1.0/ttyUSB0/tty/ttyUSB0'
        ID_BUS='usb'
        ID_MODEL='FT232R_USB_UART'
        ID_MODEL_ID='6001'
        ID_SERIAL_SHORT='A50285BI'
        ID_VENDOR_ID='0403'
        MAJOR='188'
        SUBSYSTEM='tty'
    UDEV

    def freebsd(text = UFTDI + UHUB)
        tree = D::FreeBSD.parse(text)
        tree.filter_map {|name, dev|
            next unless name.start_with?('uftdi')
            D::FreeBSD.candidate(dev, tree)
        }
    end

    def test_freebsd_reports_the_line_the_serial_and_the_path
        assert_equal({ :device   => '/dev/ttyU0',
                       :serial   => 'AL03GD7X',
                       :usb_path => '1-1.1.4.4' }, freebsd.first)
    end

    # Nothing on FreeBSD states a path: it is walked, %parent by
    # %parent, and the ports collected on the way up.  uftdi0 sits on
    # port 4 of uhub5, which is on port 4 of uhub4, which is on port 1
    # of uhub2, which is on port 1 of the root hub of bus 1.
    def test_the_path_is_walked_up_to_the_root_hub
        tree = D::FreeBSD.parse(UFTDI + UHUB)
        assert_equal '1-1.1.4', D::FreeBSD.usb_path(tree['uhub5'], tree)
        assert_equal '1-1.1',   D::FreeBSD.usb_path(tree['uhub4'], tree)
        assert_equal '0-2',     D::FreeBSD.usb_path(tree['uhub3'], tree)
    end

    # A root hub occupies no port on anything: its %location is empty.
    def test_a_root_hub_has_no_path_of_its_own
        tree = D::FreeBSD.parse(UFTDI + UHUB)
        assert_nil D::FreeBSD.usb_path(tree['uhub0'], tree)
    end

    # Without the hubs there is nothing to walk.  The half-built
    # answer is the dangerous one: the adapter's own port alone reads
    # as a whole path -- 1-4 rather than 1-1.1.4.4 -- and names a real
    # socket that is not this one.
    def test_a_walk_that_never_reaches_the_root_is_nil
        assert_nil freebsd(UFTDI).first[:usb_path]
    end

    # An unprogrammed EEPROM answers sernum="", and nothing may be
    # identified by an empty string.
    # The case the path exists for: no serial to be named by, and the
    # socket is then the only stable name it has.
    def test_an_empty_serial_is_nil_and_the_path_is_still_there
        assert_equal({ :device   => '/dev/ttyU1',
                       :serial   => nil,
                       :usb_path => '0-2.3' }, freebsd[1])
    end

    # uftdi drives every FTDI part, not only the one the hub uses.
    def test_another_ftdi_part_is_not_a_candidate
        refute_includes freebsd.map {|c| c[:device] }, '/dev/ttyU2'
        assert_equal 2, freebsd.size
    end

    # dev.uhub.%parent has no unit number in it and must not become a
    # device.  Two branches are read at once, so the key is the name.
    def test_the_driver_wide_key_is_not_taken_for_a_device
        keys = D::FreeBSD.parse(UFTDI + UHUB).keys
        assert_includes keys, 'uftdi0'
        assert_includes keys, 'uhub5'
        refute_includes keys, 'uhub'
        assert_equal 9, keys.size
    end

    # Not every token in a %pnpinfo is a key=value pair --
    # dev.acpi_timer.0.%pnpinfo is the bare word 'unknown' -- and a
    # parser that died on one driver's wording would take the hub
    # with it.
    def test_a_field_that_is_not_a_pair_does_not_stop_the_parse
        tree = D::FreeBSD.parse(<<~'SYSCTL')
            dev.uftdi.0.%pnpinfo=unknown vendor=0x0403 product=0x6001 sernum="AL03GD7X"
            dev.uftdi.0.ttyname=U0
        SYSCTL
        assert_equal '0x0403', tree['uftdi0'][:'%pnpinfo'][:vendor]
    end

    def test_nothing_attached_is_an_empty_list_not_an_error
        assert_empty freebsd('')
    end

    def test_linux_reports_the_line_the_serial_and_the_path
        assert_equal({ :device   => '/dev/ttyUSB0',
                       :serial   => 'A50285BI',
                       :usb_path => '1-1.2.4.4' },
                     D::Linux.candidate(D::Linux.parse(UDEVADM)))
    end

    # Every hub on the way to the device matches the shape too, so it
    # is the last match that is the adapter -- not 1-1, not 1-1.2.
    def test_the_usb_path_is_the_device_not_a_hub_above_it
        assert_equal '1-1.2.4.4', D::Linux.usb_path(
            '/devices/pci0000:00/usb1/1-1/1-1.2/1-1.2.4/1-1.2.4.4/' \
            '1-1.2.4.4:1.0/ttyUSB0/tty/ttyUSB0')
    end

    def test_a_devpath_with_no_usb_component_has_no_path
        assert_nil D::Linux.usb_path('/devices/platform/serial8250/ttyS0')
    end

    # The published shape, so that a caller can tell a path typed by a
    # human from a serial number.
    def test_what_a_usb_path_looks_like
        assert_match     ExSYS::ManagedUSB::USB_PATH, '1-1.2.4.4'
        assert_match     ExSYS::ManagedUSB::USB_PATH, '2-3'
        refute_match     ExSYS::ManagedUSB::USB_PATH, 'AL03GD7X'
        refute_match     ExSYS::ManagedUSB::USB_PATH, '1-1.2.4.4:1.0'
        refute_match     ExSYS::ManagedUSB::USB_PATH, '/dev/ttyUSB0'
    end

    def test_linux_skips_an_adapter_that_is_not_the_right_part
        props = D::Linux.parse(UDEVADM.sub("'6001'", "'6015'"))
        assert_nil D::Linux.candidate(props)
    end

    def test_linux_unquotes_the_export_format
        assert_equal '/dev/ttyUSB0', D::Linux.parse(UDEVADM)[:DEVNAME]
    end

    # The public name delegates, so that a caller has one thing to call.
    def test_available_is_what_the_platform_answered
        found = [ { :device   => '/dev/ttyU0', :serial => 'AL03GD7X',
                    :usb_path => nil } ]
        D.stub(:available, found) do
            assert_equal found, ExSYS::ManagedUSB.available
        end
    end

    # A platform with no way to look says so.  An empty list would read
    # as "no hub attached", which is a different thing and a lie.
    def test_a_platform_we_cannot_look_on_is_an_error
        RbConfig::CONFIG.stub(:[], 'solaris2.11') do
            e = assert_raises(ExSYS::ManagedUSB::Error) { D.available }
            assert_match(/no hub discovery for this platform/, e.message)
            assert_match(/solaris2\.11/,                       e.message)
        end
    end

    def test_a_missing_tool_is_an_error_too
        e = assert_raises(ExSYS::ManagedUSB::Error) {
            D.missing('/sbin/sysctl', Errno::ENOENT.new('/sbin/sysctl'))
        }
        assert_match(%r{cannot look for a hub: /sbin/sysctl}, e.message)
    end

    # Regression, and the reason Discovery.run exists.  This reader
    # once ran `sysctl ... 2>/dev/null` in a backtick; the redirection
    # made Ruby hand the string to /bin/sh, which reports a missing
    # binary itself as exit 127 with no output, so Errno::ENOENT never
    # reached the rescue and a host with no sysctl answered "no hub
    # attached" -- the exact lie the comment there warns against.
    #
    # The status cannot stand in for it either: sysctl exits 1 for an
    # unknown oid, which is the legitimate empty answer.
    def test_a_reader_that_is_not_installed_raises_rather_than_answering_none
        e = assert_raises(ExSYS::ManagedUSB::Error) {
            D.run('/nonexistent/sysctl', '-e', 'dev.uftdi')
        }
        assert_match(%r{cannot look for a hub: /nonexistent/sysctl},
                     e.message)
    end

    # ... and a reader that IS installed, asked for an oid this host
    # has not got, answers nothing at all rather than raising.
    def test_an_oid_that_does_not_exist_is_an_empty_answer
        assert_empty D.run('/usr/bin/env', 'true')
    end
end
