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

    def test_all_powers_every_port
        @usb.on(ExSYS::ManagedUSB::ALL)
        assert_equal ExSYS::ManagedUSB::PORTS, @hub.ports_on
    end

    def test_all_unpowers_every_port
        @usb.on(:all)
        @usb.off(:all)
        assert_empty @hub.ports_on
    end

    # Regression: an empty list used to mean every port, so a caller
    # splatting a computed list that came back empty switched all
    # sixteen.  on(*[]) and on() are the same call, so neither can be
    # allowed through.
    def test_an_empty_port_list_is_refused_not_taken_as_every_port
        @usb.on(:all)
        [ ->{ @usb.on(*[])     }, ->{ @usb.on        },
          ->{ @usb.off(*[])    }, ->{ @usb.off       },
          ->{ @usb.toggle(*[]) }, ->{ @usb.toggle    } ].each do |op|
            err = assert_raises(ArgumentError, &op)
            assert_match(/no port given/, err.message)
        end
        assert_equal ExSYS::ManagedUSB::PORTS, @hub.ports_on,
                     'the hub must not have been touched'
    end

    def test_all_cannot_be_mixed_with_port_numbers
        assert_raises(ArgumentError) { @usb.on(:all, 3) }
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
        assert_same @usb, @usb.on(:all)
        @usb.on(:all).off(4, 5, 6)
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

    # Each refusal names what it refused.  These used to be bare
    # ArgumentErrors, whose message was the class name and which left a
    # caller with sixteen ports to find the typo among by hand.
    def test_set_refuses_a_mixed_or_unknown_notation
        err = assert_raises(ArgumentError) {
            @usb.set({ :on => [ 1 ], 2 => :off })
        }
        assert_match(/neither/, err.message)
        assert_match(/:on/,     err.message)

        err = assert_raises(ArgumentError) { @usb.set({ :bogus => [ 1 ] }) }
        assert_match(/:bogus/, err.message)

        err = assert_raises(ArgumentError) {
            @usb.set({ 1 => true, 7 => :perhaps })
        }
        assert_match(/not a port state/, err.message)
        assert_match(/7/,                err.message)
        assert_match(/:perhaps/,         err.message)
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
        @usb.on(:all)
        assert_equal({ :on => ExSYS::ManagedUSB::PORTS, :off => [] },
                     @usb.get(:on_off))
        @usb.off(1)
        assert_equal [ 1 ], @usb.get(:on_off)[:off]
    end

    # A real hub answers in upper case; accept either, since the reply
    # is only ever fed to pack('H4'), which does not care.
    def test_a_lower_case_reply_decodes_the_same
        @usb.port_count              # settle ?Q before garbling every reply
        @hub.garbage = 'c4ffffff'
        assert_equal [ 3, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 ], @usb.get(:on)
        @hub.garbage = 'C4FFFFFF'
        assert_equal [ 3, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 ], @usb.get(:on)
    end

    # Refused by name, and before the line is opened: an unknown type
    # is a typo and nothing the hub can answer, so it used to cost a GP
    # and a ?Q and then raise a bare ArgumentError whose message was
    # the class name.
    def test_get_refuses_an_unknown_type
        @usb.port_count                  # the one-off ?Q, out of the way
        @hub.log.clear
        err = assert_raises(ArgumentError) { @usb.get(:bogus) }
        assert_match(/unknown type/, err.message)
        assert_match(/:bogus/,       err.message)
        assert_empty @hub.log, 'a typo must not reach the hub'
    end

    ## Flash and reset ###################################################

    def test_commit_saves_the_state_as_the_power_on_state
        @usb.on(1)
        @usb.commit
        assert_equal [ 1 ], @hub.flash_ports
    end

    # RD is the hub's "restore factory defaults", not the inverse of
    # commit: there is no command that reloads the flashed state, the
    # hub applies it at power-on by itself.  Modelled from the vendor's
    # own documentation -- running it against hardware would drop every
    # port on the bench and reset the password.
    ## Describing the hub ###############################################

    def test_query_reports_id_ports_and_firmware
        assert_equal({ :id => 'CENTOS', :ports => 16, :firmware => 'v02',
                       :raw => 'CENTOS000516v02' }, @usb.query)
    end

    def test_query_needs_no_password
        usb = ExSYS::ManagedUSB.new('/dev/null', 'wrong')
        assert_equal 16, usb.query[:ports]
    end

    # The hub is asked how many ports it has before it is read, not
    # somewhere in the middle: a trace of any port operation reads the
    # same way, and an invalid port is refused without touching it.
    def test_the_query_leads_and_happens_once
        @usb.on(1)
        assert_equal %w[?Q GP SP], (@hub.log.map {|c| c[0, 2] })

        @hub.log.clear
        @usb.off(2)
        assert_equal %w[GP SP], (@hub.log.map {|c| c[0, 2] })
    end

    def test_an_invalid_port_is_refused_before_the_hub_is_read
        assert_raises(ArgumentError) { @usb.on(99) }
        assert_equal %w[?Q], (@hub.log.map {|c| c[0, 2] })
    end

    def test_port_count_is_asked_once_and_remembered
        3.times { @usb.port_count }
        assert_equal 1, @hub.log.count('?Q')
    end

    # Firmware that does not know ?Q answers an error, and the count
    # falls back to what the state word can address.
    def test_port_count_falls_back_when_the_hub_refuses_the_query
        @hub.ident = nil                        # answers E01
        assert_equal ExSYS::ManagedUSB::PORTS.size, @usb.port_count
        assert_match(/will not answer/, @dbg.string)
    end

    # A reply that arrives but cannot be read is a different thing from
    # a refusal, and must not be guessed at: on a wider hub a guess of
    # sixteen would leave its upper ports untouched while reporting
    # success.
    def test_an_unreadable_query_reply_does_not_become_a_guess
        @hub.ident = 'CENTOS-garbled'
        assert_raises(ExSYS::ManagedUSB::Error) { @usb.port_count }
        assert_raises(ExSYS::ManagedUSB::Error) { @usb.on(:all) }
    end

    # The firmware is whatever follows the count, not a bare number:
    # a hub reporting v1.02 must not fall back to a guessed count.
    def test_a_dotted_firmware_version_still_parses
        @hub.ident = 'CENTOS000532v1.02'
        assert_equal 32,      @usb.query[:ports]
        assert_equal 'v1.02', @usb.query[:firmware]
        assert_equal 32,      @usb.port_count
    end

    def test_an_unparseable_query_reply_is_an_error
        @hub.ident = 'wat'
        err = assert_raises(ExSYS::ManagedUSB::Error) { @usb.query }
        assert_match(/unexpected query reply/, err.message)
    end

    # ALL means every port the hub says it has.  Confirmed against the
    # vendor tool, which reads the same field and reports 4, 8, 16 or
    # 32 ports from it.
    def test_all_covers_exactly_the_ports_the_hub_reports
        @hub.ident = 'CENTOS000504v02'          # a hub with 4 ports
        @usb.on(:all)
        assert_equal [ 1, 2, 3, 4 ], @hub.ports_on
        assert_equal [ 1, 2, 3, 4 ], @usb.ports
    end

    def test_a_port_the_hub_does_not_have_is_refused
        @hub.ident = 'CENTOS000504v02'
        assert_raises(ArgumentError) { @usb.on(5) }
    end

    ## Hubs that are not sixteen ports ##################################

    # Regression: the state word's upper half was written as a literal
    # 'ffff' rather than carried back from the read.  On a 16-port hub
    # those bits are ports that do not exist and it went unnoticed; on
    # a 32-port hub it powered ports 17..32 on every single operation.
    def test_a_wider_hub_does_not_have_its_upper_ports_driven
        UART.hub = wide = FakeHub.new(ports: 32, width: 8)
        usb = ExSYS::ManagedUSB.new('/dev/null')

        usb.on(1)
        assert_equal [ 1 ], wide.ports_on
    end

    def test_a_wider_hub_can_use_all_of_its_ports
        UART.hub = wide = FakeHub.new(ports: 32, width: 8)
        usb = ExSYS::ManagedUSB.new('/dev/null')

        assert_equal 32, usb.port_count
        usb.on(:all)
        assert_equal (1..32).to_a, wide.ports_on
        usb.off(20)
        assert_equal (1..32).to_a - [ 20 ], wide.ports_on
    end

    def test_a_narrower_hub_reports_only_the_ports_it_has
        UART.hub = small = FakeHub.new(ports: 4, width: 8)
        usb = ExSYS::ManagedUSB.new('/dev/null')

        assert_equal [ 1, 2, 3, 4 ], usb.ports
        usb.on(:all)
        assert_equal [ 1, 2, 3, 4 ], small.ports_on
        assert_equal({ 1 => true, 2 => true, 3 => true, 4 => true },
                     usb.get)
        assert_raises(ArgumentError) { usb.on(5) }
    end

    # The ports it does not have read as 1, and must be written back
    # that way rather than cleared.
    def test_absent_ports_are_carried_back_untouched
        UART.hub = small = FakeHub.new(ports: 4, width: 8)
        usb = ExSYS::ManagedUSB.new('/dev/null')

        usb.on(1)
        # Little-endian: ports 1..8 in the first byte, so port 1 on with
        # ports 5..32 absent and reading 1 is F1 FF FF FF.
        assert_equal 'F1FFFFFF', small.log.last[-8..],
                     'absent ports written back as read'
    end

    ## Factory reset #####################################################

    def test_the_old_restore_name_is_a_tombstone
        err = assert_raises(NoMethodError) { @usb.restore }
        assert_match(/renamed factory_reset/, err.message)
        assert_match(/not the inverse of commit/, err.message)
    end

    def test_factory_reset_refuses_unless_it_is_confirmed
        @usb.on(:all)
        err = assert_raises(ArgumentError) { @usb.factory_reset }
        assert_match(/confirm: true/, err.message)
        assert_equal ExSYS::ManagedUSB::PORTS, @hub.ports_on,
                     'the hub must not have been touched'
    end

    def test_restore_is_a_factory_reset
        @usb.on(1)
        @usb.commit
        @usb.on(:all)
        @usb.factory_reset(confirm: true)
        assert_empty @hub.ports_on,  'every port dropped'
        assert_empty @hub.flash_ports, 'the power-on state went too'
        assert_equal FakeHub::DEFAULT_PASSWORD, @hub.password
    end

    # Regression: RD puts the hub's password back to the default, and
    # this object went on holding the old one.  Every later command was
    # then refused by the hub that had just done what it was told --
    # E01, with nothing on the wire saying why.  Only reachable on a hub
    # whose password is NOT the default, which is why the test above,
    # running on a default-password hub, could not see it.
    def test_factory_reset_forgets_the_password_the_hub_dropped
        UART.hub = hub = FakeHub.new(password: 's3cret'.ljust(8))
        usb      = ExSYS::ManagedUSB.new('/dev/null', 's3cret')

        usb.factory_reset(confirm: true)
        usb.on(2)

        assert_equal [ 2 ], hub.ports_on
        assert_equal 'SPpass    0200FFFF', hub.log.last,
                     'the frame must carry the password the hub now has'
    end

    def test_on_with_commit_writes_through_to_flash
        @usb.on(3, commit: true)
        @usb.on(4)
        assert_equal [ 3, 4 ], @hub.ports_on
        assert_equal [ 3 ],    @hub.flash_ports
    end

    def test_reset_expects_no_reply
        assert_same @usb, @usb.reset(confirm: true)
    end

    def test_reset_refuses_unless_it_is_confirmed
        @usb.on(:all)
        err = assert_raises(ArgumentError) { @usb.reset }
        assert_match(/confirm: true/, err.message)
        refute_includes @hub.log.map {|c| c[0, 2] }, 'RH'
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

    # Regression, and the same defect as the one above on the other
    # path: a command whose reply is CHECKED -- commit, reset,
    # factory_reset, password, and the SP behind every switch -- read
    # the reply as an Exx code without first establishing it was one.
    # data[1..-1] of '' is nil, and an Error raised with nil carries the
    # class name as its message: a silent hub, which is also what a
    # timed-out read looks like, reported itself as
    # 'exsys-usb: ExSYS::ManagedUSB::Error' and nothing more.
    def test_a_silent_hub_says_so_on_a_checked_command
        @hub.silent = true
        err = assert_raises(ExSYS::ManagedUSB::Error) { @usb.commit }
        assert_match(/unexpected reply/, err.message)
    end

    # ... and of a one-character reply it is '', an error with no
    # message at all.  Anything that is not an Exx is reported as what
    # arrived, not as a code the hub never sent.
    def test_a_reply_too_short_to_be_a_code_is_not_read_as_one
        @hub.garbage = 'X'
        err = assert_raises(ExSYS::ManagedUSB::Error) { @usb.commit }
        assert_match(/unexpected reply/, err.message)
        assert_match(/"X"/,              err.message)
    end

    # The Exx path itself still answers with the code alone, which is
    # what the wrong-password test above reads.
    def test_a_refusal_on_a_checked_command_is_still_just_its_code
        @hub.garbage = 'E42'
        err = assert_raises(ExSYS::ManagedUSB::Error) { @usb.commit }
        assert_equal '42', err.message
    end

    ## The serial line ###################################################

    # Regression: a read-modify-write used to close the line between the
    # GP and the SP, letting another process slip in between the two.
    def test_read_modify_write_holds_the_line_open
        @usb.port_count                        # the one-off ?Q, out of the way
        @hub.log.clear
        @usb.on(1)
        assert_equal 2, @hub.log.size          # GP then SP, one session
        assert_equal %w[GP SP], (@hub.log.map {|c| c[0, 2] })
    end

    def test_set_holds_the_line_open_too
        @usb.set({ 1 => true })
        assert_equal 1, @hub.opens             # ?Q, GP and SP all inside it
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

    # Regression: EBADF and EINVAL were swallowed alongside the genuine
    # "this platform will not lock this" errors.  Both mean a bug here,
    # and swallowing one runs unlocked while reporting success.
    def test_an_unexpected_lock_error_is_not_swallowed
        @hub.lock_error = Errno::EBADF
        assert_raises(Errno::EBADF) { @usb.on(1) }
    end

    ## Sessions #########################################################

    def test_session_yields_the_hub_and_returns_the_block_value
        result = @usb.session {|h| assert_same @usb, h; :done }
        assert_equal :done, result
    end

    def test_one_session_holds_one_line_for_every_call_inside_it
        @usb.session do
            @usb.get
            @usb.on(1)
            @usb.off(1)
        end
        assert_equal 1, @hub.opens
        assert_equal 1, @hub.locks
    end

    def test_without_a_session_each_call_opens_its_own_line
        @usb.get
        @usb.on(1)
        assert_equal 2, @hub.opens
    end

    def test_a_session_releases_the_line_even_when_the_block_raises
        assert_raises(RuntimeError) { @usb.session { raise 'boom' } }
        @usb.on(1)                       # must open afresh, not reuse
        assert_equal 2, @hub.opens
        assert_equal [ 1 ], @hub.ports_on
    end

    # Regression: the open line was plain instance state, so a second
    # thread either borrowed a line it held no lock on -- losing one
    # thread's change -- or had it closed underneath it by the first
    # thread's ensure, which surfaced as a NoMethodError on nil.
    def test_two_threads_never_share_one_line
        Dir.mktmpdir('exsys-threads') do |dir|
            fake = FakeHub.new(path: File.join(dir, 'hub'),
                               lock: File.join(dir, 'lock'), delay: 0.2)
            UART.hub = fake
            usb = ExSYS::ManagedUSB.new('/dev/null')

            a = Thread.new { usb.on(1) }
            sleep 0.1                    # B enters while A holds the line
            b = Thread.new { usb.on(2) }
            [ a, b ].each(&:join)

            assert_equal 2, fake.opens, 'each thread opens its own line'
            assert_equal 2, fake.locks, 'each thread takes its own lock'
            assert_equal [ 1, 2 ], fake.ports_on
        end
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
