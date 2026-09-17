require_relative 'helper'

# The README documents the executable by name and by example.  Both can
# drift away from the tool without anything saying so -- the name did,
# and sat wrong through four releases -- so both are checked here.
class TestReadme < Minitest::Test
    include CLI

    README = File.read(File.join(ROOT, 'README.md')).freeze

    # Regression: every example named `exsys-hub`, which has never been
    # the name of anything this gem installs.
    def test_the_shell_examples_name_the_real_executable
        named = shell_commands.map {|line| line.split.first }.uniq
                              .grep(/\Aexsys/)

        refute_empty named, 'no exsys command appears in the README'
        assert_equal [ File.basename(EXE) ], named
    end

    # And each example must still be one the tool accepts, so that a
    # renamed action or a changed argument syntax cannot sit in the
    # documentation unnoticed.
    def test_every_documented_example_is_accepted
        examples = documented_examples
        assert_operator examples.size, :>=, 6, 'README examples went missing'

        examples.each do |line, argv|
            _, err, st = exsys_usb_raw(argv)
            assert_equal 0, st.exitstatus,
                         "README example is not accepted: #{line}\n#{err}"
        end
    end

    def test_the_documented_test_command_is_the_one_that_runs
        assert_includes shell_commands, 'rake test'
    end

    private

    # Command lines from the README's shell blocks, comments and blank
    # lines removed.
    def shell_commands
        README.scan(/^~~~sh$(.*?)^~~~$/m).flatten.join("\n")
              .lines.map {|l| l.sub(/#.*/, '').strip }.reject(&:empty?)
    end

    # Those that invoke the executable, as [ line, argv ].  The shell
    # variable the README uses for the device is replaced by one that
    # exists everywhere, and anything the shell would interpret rather
    # than pass on -- a pipe, a conditional, a redirection -- is cut
    # off, since these run the executable directly and not under a
    # shell.  What is checked is the invocation, not the plumbing.
    def documented_examples
        shell_commands.filter_map do |line|
            next unless line.start_with?(File.basename(EXE))
            cmd = line.split(/\s(?:\|\||&&|\||;|>>?)\s/).first
            [ line, Shellwords.split(cmd.sub('${dev}', '/dev/null'))[1..] ]
        end
    end
end
