require_relative 'helper'

# Library-level behaviour of ExSYS::ManagedUSB, driven against FakeHub.
class TestManagedUSB < Minitest::Test
    def setup
        UART.reset!
        UART.hub = @hub = FakeHub.new
        @dbg     = StringIO.new
        @usb     = ExSYS::ManagedUSB.new('/dev/null', debug: @dbg)
    end

    ## Switching #########################################################

    def test_on_without_argument_powers_every_port
        @usb.on
        assert_equal ExSYS::ManagedUSB::PORTS, @hub.ports_on
    end

    def test_off_without_argument_powers_nothing
        @usb.on
        @usb.off
        assert_empty @hub.ports_on
    end

    def test_on_and_off_are_restricted_to_the_named_ports
        @usb.on(1, 2, 16)
        assert_equal [ 1, 2, 16 ], @hub.ports_on
        @usb.off(2)
        assert_equal [ 1, 16 ], @hub.ports_on
    end

    def test_toggle_inverts_the_named_ports_only
        @usb.on(1, 3)
        @usb.toggle(3, 4)
        assert_equal [ 1, 4 ], @hub.ports_on
    end

    def test_switching_returns_self_so_calls_chain
        assert_same @usb, @usb.on
        @usb.on.off(4, 5, 6)
        assert_equal ExSYS::ManagedUSB::PORTS - [ 4, 5, 6 ], @hub.ports_on
    end

    ## Port validation -- regression, ports outside 1..16 used to be
    ## accepted and then silently shifted or truncated away, so that the
    ## hub was rewritten with its existing state and the caller was told
    ## the switch had happened.
    ######################################################################

    def test_port_zero_is_rejected_by_every_entry_point
        [ ->{ @usb.on(0)  }, ->{ @usb.off(0) },
          ->{ @usb.toggle(0) }, ->{ @usb.set({ :on => [ 0 ] }) } ].each do |op|
            assert_raises(ArgumentError, &op)
        end
    end

    def test_port_above_the_last_one_is_rejected
        [ 17, 99, 1_000 ].each do |p|
            err = assert_raises(ArgumentError) { @usb.on(p) }
            assert_match(/invalid port/, err.message)
        end
    end

    def test_negative_port_is_rejected
        assert_raises(ArgumentError) { @usb.on(-1) }
    end

    def test_a_rejected_port_leaves_the_hub_untouched
        @usb.on(1)
        assert_raises(ArgumentError) { @usb.on(17) }
        assert_equal [ 1 ], @hub.ports_on
    end

    def test_set_rejects_an_out_of_range_port_in_either_notation
        assert_raises(ArgumentError) { @usb.set({ 99 => :on }) }
        assert_raises(ArgumentError) { @usb.set({ :on => [ 99 ] }) }
        assert_raises(ArgumentError) { @usb.set({ :off => [ 0 ] }) }
    end

    ## set ###############################################################

    def test_set_by_port_value
        @usb.set({ 1 => true, 2 => false, 3 => :on, 4 => :OFF, 5 => 1 })
        assert_equal [ 1, 3, 5 ], @hub.ports_on
    end

    def test_set_by_port_state
        @usb.set({ :on => [ 1, 3 ], :off => 4 })
        assert_equal [ 1, 3 ], @hub.ports_on
    end

    def test_set_leaves_unlisted_ports_alone_without_a_default
        @usb.on(8)
        @usb.set({ 1 => true })
        assert_equal [ 1, 8 ], @hub.ports_on
    end

    def test_set_applies_the_default_to_unlisted_ports
        @usb.on(8)
        @usb.set({ 1 => true }, false)
        assert_equal [ 1 ], @hub.ports_on
    end

    def test_set_treats_an_explicit_nil_as_leave_as_is
        @usb.on(8)
        @usb.set({ 1 => true, 8 => nil }, false)
        assert_equal [ 1, 8 ], @hub.ports_on
    end

    def test_set_refuses_a_port_named_both_on_and_off
        err = assert_raises(ArgumentError) do
            @usb.set({ :on => [ 1 ], :off => [ 1 ] })
        end
        assert_match(/overlap/, err.message)
    end

    def test_set_refuses_a_mixed_or_unknown_notation
        assert_raises(ArgumentError) { @usb.set({ :on => [ 1 ], 2 => :off }) }
        assert_raises(ArgumentError) { @usb.set({ :bogus => [ 1 ] })        }
        assert_raises(ArgumentError) { @usb.set({ 1 => :perhaps })          }
    end

    ## get ###############################################################

    def test_get_ports
        @usb.on(2)
        assert_equal true,  @usb.get[2]
        assert_equal false, @usb.get[3]
        assert_equal ExSYS::ManagedUSB::PORTS, @usb.get.keys
    end

    def test_get_on_and_off_lists
        @usb.on(2, 5)
        assert_equal [ 2, 5 ], @usb.get(:on)
        assert_equal ExSYS::ManagedUSB::PORTS - [ 2, 5 ], @usb.get(:off)
    end

    # Regression: the :on_off hash used to grow a key only for a state
    # that actually occurred, so a hub with every port alike answered
    # with one key and a caller reading the other got nil.
    def test_get_on_off_always_carries_both_keys
        assert_equal({ :on => [], :off => ExSYS::ManagedUSB::PORTS },
                     @usb.get(:on_off))
        @usb.on
        assert_equal({ :on => ExSYS::ManagedUSB::PORTS, :off => [] },
                     @usb.get(:on_off))
        @usb.off(1)
        assert_equal [ 1 ], @usb.get(:on_off)[:off]
    end

    # A real hub answers in upper case; accept either, since the reply
    # is only ever fed to pack('H4'), which does not care.
    def test_a_lower_case_reply_decodes_the_same
        @hub.garbage = 'c4ffffff'
        assert_equal [ 3, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 ], @usb.get(:on)
        @hub.garbage = 'C4FFFFFF'
        assert_equal [ 3, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 ], @usb.get(:on)
    end

    def test_get_refuses_an_unknown_type
        assert_raises(ArgumentError) { @usb.get(:bogus) }
    end

    ## Flash and reset ###################################################

    def test_commit_saves_and_restore_brings_back
        @usb.on(1)
        @usb.commit
        @usb.on(2)
        assert_equal [ 1, 2 ], @hub.ports_on
        @usb.restore
        assert_equal [ 1 ], @hub.ports_on
    end

    def test_on_with_commit_writes_through_to_flash
        @usb.on(3, commit: true)
        @usb.on(4)
        @usb.restore
        assert_equal [ 3 ], @hub.ports_on
    end

    def test_reset_expects_no_reply
        assert_same @usb, @usb.reset
    end

    ## Password ##########################################################

    def test_default_password_is_padded_to_eight
        @usb.on(1)
        assert_equal 'SPpass    0100FFFF', @hub.log.last
    end

    def test_password_longer_than_eight_is_refused
        assert_raises(ArgumentError) do
            ExSYS::ManagedUSB.new('/dev/null', 'verylongpassword')
        end
    end

    def test_wrong_password_raises_with_the_hub_code
        usb = ExSYS::ManagedUSB.new('/dev/null', 'nope')
        err = assert_raises(ExSYS::ManagedUSB::Error) { usb.on(1) }
        assert_equal '01', err.message
    end

    def test_password_change_is_accepted_by_the_hub
        @usb.password('secret')
        assert_equal 'secret'.ljust(8), @hub.password
        @usb.on(1)                       # still authenticated afterwards
        assert_equal [ 1 ], @hub.ports_on
    end

    ## Debug output ######################################################

    def test_debug_traces_both_directions
        @usb.on(1)
        assert_match(/<-- GP/,       @dbg.string)
        assert_match(/--> 0000FFFF/, @dbg.string)
    end

    # Regression: the password used to be traced verbatim, putting it in
    # a file that was also created world-readable.
    def test_debug_never_carries_the_password
        usb = ExSYS::ManagedUSB.new('/dev/null', 's3cret', debug: @dbg)
        @hub.password = 's3cret'.ljust(8)
        usb.on(1)
        usb.commit
        usb.password('other')
        refute_match(/s3cret/, @dbg.string)
        refute_match(/other/,  @dbg.string)
        assert_match(/<-- SP\*{8}/, @dbg.string)
    end

    ## Malformed replies #################################################

    def test_error_reply_to_a_read_is_raised_with_its_code
        @hub.garbage = 'E42'
        err = assert_raises(ExSYS::ManagedUSB::Error) { @usb.get }
        assert_equal '42', err.message
    end

    # Regression: a reply of an unexpected length used to raise a bare
    # Error, whose message was just the class name.
    def test_unexpected_reply_length_says_what_arrived
        @hub.garbage = 'wat'
        err = assert_raises(ExSYS::ManagedUSB::Error) { @usb.get }
        assert_match(/unexpected reply/, err.message)
        assert_match(/wat/,              err.message)
    end

    def test_silent_hub_is_an_error_not_a_hang
        @hub.silent = true
        assert_raises(ExSYS::ManagedUSB::Error) { @usb.get }
    end

    ## The serial line ###################################################

    # Regression: a read-modify-write used to close the line between the
    # GP and the SP, letting another process slip in between the two.
    def test_read_modify_write_holds_the_line_open
        @usb.on(1)
        assert_equal 1, @hub.opens
        assert_equal 2, @hub.log.size          # GP then SP, one session
    end

    def test_set_holds_the_line_open_too
        @usb.set({ 1 => true })
        assert_equal 1, @hub.opens
    end

    def test_the_line_is_opened_as_the_hub_expects
        @usb.on(1)
        assert_equal '/dev/null',              @hub.line
        assert_equal ExSYS::ManagedUSB::SPEED, @hub.speed
        assert_equal 9600,                     @hub.speed
        assert_equal '8N1',                    @hub.mode
    end

    def test_the_line_is_locked_while_held
        @usb.on(1)
        assert_equal 1, @hub.locks
    end

    # A platform that will not lock a character device must not make the
    # tool unusable; it degrades to unlocked and says so.
    def test_an_unlockable_line_degrades_rather_than_failing
        @hub.lockable = false
        @usb.on(1)
        assert_equal [ 1 ], @hub.ports_on
        assert_match(/not lockable/, @dbg.string)
    end
end
