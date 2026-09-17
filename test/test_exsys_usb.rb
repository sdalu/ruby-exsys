require_relative 'helper'

# Behaviour of the bin/exsys-usb executable, run as a subprocess so
# that its exit status -- what a calling script actually reads -- is
# part of what is asserted.
class TestExsysUsb < Minitest::Test
    include CLI

    ## Switching #########################################################

    def test_on_and_off_reach_the_hub
        _, _, st = exsys_usb('on', '1', '2')
        assert_predicate st, :success?
        assert_equal [ 1, 2 ], hub.ports_on

        exsys_usb('off', '1')
        assert_equal [ 2 ], hub.ports_on
    end

    def test_bare_on_and_off_cover_every_port
        exsys_usb('on')
        assert_equal ExSYS::ManagedUSB::PORTS, hub.ports_on
        exsys_usb('off')
        assert_empty hub.ports_on
    end

    def test_toggle
        exsys_usb('on', '1', '3')
        exsys_usb('toggle', '3', '4')
        assert_equal [ 1, 4 ], hub.ports_on
    end

    def test_set_pairs
        exsys_usb('on', '5')
        _, _, st = exsys_usb('set', '3:on', '5:off')
        assert_predicate st, :success?
        assert_equal [ 3 ], hub.ports_on
    end

    def test_set_accepts_every_documented_spelling
        exsys_usb('set', '1:on', '2:ON', '3:true', '4:t', '5:1')
        assert_equal [ 1, 2, 3, 4, 5 ], hub.ports_on
        exsys_usb('set', '1:off', '2:OFF', '3:false', '4:f', '5:0')
        assert_empty hub.ports_on
    end

    def test_default_flag_forces_the_unlisted_ports
        exsys_usb('on', '8')
        exsys_usb('-D', 'false', 'set', '3:on')
        assert_equal [ 3 ], hub.ports_on
    end

    def test_commit_and_restore
        exsys_usb('on', '1')
        exsys_usb('commit')
        exsys_usb('on', '2')
        exsys_usb('restore')
        assert_equal [ 1 ], hub.ports_on
    end

    def test_commit_flag_writes_through
        exsys_usb('-c', 'on', '4')
        exsys_usb('on', '5')
        exsys_usb('restore')
        assert_equal [ 4 ], hub.ports_on
    end

    ## Exit status -- regression.  Every failure used to be printed and
    ## then exited 0, so that `exsys-usb off 3 || alert` never fired.
    ######################################################################

    def test_a_refused_command_exits_non_zero
        seed_hub(password: 'other')
        _, err, st = exsys_usb('off', '3')
        refute_predicate st, :success?
        assert_equal 1, st.exitstatus
        assert_match(/exsys-usb: 01/, err)
    end

    def test_a_silent_hub_exits_non_zero
        _, err, st = exsys_usb('off', '3', env: { 'EXSYS_TEST_SILENT' => '1' })
        assert_equal 1, st.exitstatus
        assert_match(/exsys-usb:/, err)
    end

    def test_a_successful_command_exits_zero
        _, _, st = exsys_usb('on', '1')
        assert_equal 0, st.exitstatus
    end

    ## Argument handling #################################################

    # Regression: a port outside 1..16, or a word that to_i turned into
    # 0, used to be accepted and quietly do nothing.
    def test_an_out_of_range_port_is_refused
        [ '0', '17', '99' ].each do |p|
            _, err, st = exsys_usb('on', p)
            assert_equal 1, st.exitstatus, "port #{p} should be refused"
            assert_match(/invalid port: #{p}/, err)
        end
    end

    def test_a_port_that_is_not_a_number_is_refused
        _, err, st = exsys_usb('off', 'usb3')
        assert_equal 1, st.exitstatus
        assert_match(/invalid port/, err)
    end

    def test_a_refused_port_leaves_the_hub_alone
        exsys_usb('on', '1')
        exsys_usb('on', '17')
        assert_equal [ 1 ], hub.ports_on
    end

    # Regression: an action the case did not know fell through it, so
    # the tool exited 0 having done nothing at all.
    def test_an_unknown_action_is_refused
        _, err, st = exsys_usb('onn', '1')
        assert_equal 1, st.exitstatus
        assert_match(/unknown action: onn/, err)
    end

    def test_a_malformed_set_pair_is_refused
        [ 'foo', '3:maybe', ':on', '3:' ].each do |a|
            _, err, st = exsys_usb('set', a)
            assert_equal 1, st.exitstatus, "#{a} should be refused"
            assert_match(/invalid argument/, err)
        end
    end

    ## Startup failures -- regression.  Option parsing, the debug file
    ## and the hub were all built before the rescue, so their failures
    ## escaped as a Ruby backtrace.
    ######################################################################

    def test_an_over_long_password_is_reported_not_dumped
        _, err, st = exsys_usb('-p', 'verylongpassword', 'on', '1')
        assert_equal 1, st.exitstatus
        assert_equal "exsys-usb: password too long\n", err
    end

    def test_an_unopenable_debug_file_is_reported_not_dumped
        _, err, st = exsys_usb('--debug=/nonexistent-dir/x.log', 'on', '1')
        assert_equal 1, st.exitstatus
        assert_match(/\Aexsys-usb: /, err)
        refute_match(/\.rb:\d+:in/, err)
    end

    def test_a_bad_option_value_is_reported_not_dumped
        _, err, st = exsys_usb('-D', '0', 'set', '3:on')
        assert_equal 1, st.exitstatus
        assert_match(/\Aexsys-usb: /, err)
        refute_match(/\.rb:\d+:in/, err)
    end

    ## Help ##############################################################

    def test_no_action_prints_the_usage
        out, _, st = exsys_usb
        assert_equal 0, st.exitstatus
        assert_match(/Usage: exsys-usb ACTION/, out)
    end

    def test_help_and_version
        out, _, st = exsys_usb('-h')
        assert_equal 0, st.exitstatus
        assert_match(/--device/, out)

        out, _, st = exsys_usb('-V')
        assert_equal 0, st.exitstatus
        assert_match(/#{ExSYS::VERSION}/, out)
    end

    ## Debug file ########################################################

    # Regression: opened RDWR without truncating, so a shorter session
    # left the tail of a longer previous one in place, reading as if the
    # hub had sent it.
    def test_the_debug_file_is_appended_to
        log = File.join(@tmp, 'debug.log')
        File.write(log, "PREVIOUS SESSION#{'.' * 200}\n")
        exsys_usb("--debug=#{log}", 'on', '1')
        assert_match(/\APREVIOUS SESSION/, File.read(log))
        assert_match(/<-- GP/,             File.read(log))
        refute_match(/\.{20}\z/,           File.read(log).lines.last)
    end

    def test_two_runs_both_survive_in_the_debug_file
        log = File.join(@tmp, 'debug.log')
        exsys_usb("--debug=#{log}", 'on', '1')
        exsys_usb("--debug=#{log}", 'off', '1')
        assert_equal 2, File.read(log).scan(/<-- GP/).size
    end

    # Regression: the trace carries the password, in a file that used to
    # be created world-readable.
    def test_the_debug_file_is_private_and_redacted
        log = File.join(@tmp, 'debug.log')
        seed_hub(password: 's3cret')
        exsys_usb('-p', 's3cret', "--debug=#{log}", 'on', '1')
        assert_equal 0o600, File.stat(log).mode & 0o777
        refute_match(/s3cret/,      File.read(log))
        assert_match(/<-- SP\*{8}/, File.read(log))
    end

    ## Concurrency #######################################################

    # Regression: the GP and the SP were separate openings of the line,
    # so two processes could both read the old state and the second
    # write would drop the first one's port.
    def test_two_concurrent_invocations_do_not_lose_an_update
        env = { 'EXSYS_TEST_LOCK'  => File.join(@tmp, 'lock'),
                'EXSYS_TEST_DELAY' => '0.2' }

        results = [ '1', '2' ].map do |port|
            Thread.new { exsys_usb('on', port, env: env) }
        end.map(&:value)

        results.each {|(_, err, st)| assert_equal 0, st.exitstatus, err }
        assert_equal [ 1, 2 ], hub.ports_on
    end

    ## Packaging #########################################################

    # Regression: the file carried a shebang but no execute bit, so a
    # fresh clone could not run the examples in the README.
    def test_the_executable_is_executable
        assert_predicate File.stat(EXE).mode & 0o111, :positive?
    end
end
