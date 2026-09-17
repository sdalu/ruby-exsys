require 'minitest/autorun'
require 'fileutils'
require 'stringio'
require 'open3'
require 'shellwords'
require 'tmpdir'

ROOT = File.expand_path('..', __dir__)

# test/support carries the `uart` double, and must come before the real
# gem so that nothing here ever touches a serial line.
$LOAD_PATH.unshift File.join(ROOT, 'test', 'support')
$LOAD_PATH.unshift File.join(ROOT, 'lib')

require 'exsys'

# Run the executable in a subprocess, against a file-backed FakeHub.
#
# Returns [stdout, stderr, status]; the hub's state is left in the file
# so the caller can assert on what the ports actually did.
module CLI
    EXE = File.join(ROOT, 'bin', 'exsys-usb')

    def exsys_usb(*args, env: {})
        exsys_usb_raw([ '-d', '/dev/null', *args ], env: env)
    end

    # As above, but with nothing added to the arguments -- for running a
    # command line exactly as some other artifact spells it.
    def exsys_usb_raw(args, env: {})
        Open3.capture3({ 'EXSYS_TEST_HUB' => hub_file }.merge(env),
                       RbConfig.ruby,
                       '-I', File.join(ROOT, 'test', 'support'),
                       '-I', File.join(ROOT, 'lib'),
                       EXE, *args)
    end

    # The hub the subprocesses share, as this test left it.
    def hub = FakeHub.new(path: hub_file)

    def hub_file = @hub_file ||= File.join(@tmp, 'hub')

    # Put the shared hub into a known state -- a test needing the hub to
    # hold a particular password calls this before running anything.
    def seed_hub(password: FakeHub::DEFAULT_PASSWORD, state: 0x0000)
        FileUtils.rm_f(hub_file)
        FakeHub.new(path: hub_file, password: password.ljust(8), state: state)
    end

    def setup
        super
        @tmp = Dir.mktmpdir('exsys-test')
        seed_hub
    end

    def teardown
        FileUtils.remove_entry(@tmp) if @tmp
        super
    end
end
