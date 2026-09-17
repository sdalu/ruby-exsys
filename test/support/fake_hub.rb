# A model of the ExSYS managed hub's serial protocol, faithful enough
# to drive ExSYS::ManagedUSB end to end without hardware.
#
# The wire encoding here is written out independently of the library's
# own pack/unpack, so that a disagreement between the two shows up as a
# test failure rather than both sharing the same mistake.
class FakeHub
    DEFAULT_PASSWORD = 'pass'.ljust(8)

    attr_reader   :log, :opens, :locks, :line, :speed, :mode, :lock_path
    attr_accessor :password, :silent, :lockable, :garbage, :lock_error,
                  :ident

    # @param state    [Integer] initial port bitmap
    # @param path     [String]  file backing the state, so that separate
    #                            processes share one hub
    # @param lock     [String]  file used for a real flock, so that the
    #                            locking is genuinely exercised
    # @param delay    [Float]   pause inside a write, widening the
    #                            window a concurrent process could slip
    #                            into
    def initialize(password: DEFAULT_PASSWORD, state: 0x0000,
                   path: nil, lock: nil, delay: 0)
        @password = password
        @state    = state
        @flash    = state
        @path     = path
        @lock_path = lock
        @delay    = delay
        @log      = []
        @opens    = 0
        @locks    = 0
        @silent   = false     # hub answers nothing at all
        @lockable = true      # platform allows locking the line
        @garbage  = nil       # hub answers this instead, when set
        @lock_error = nil     # raised by flock; for the propagation test
        @ident    = 'CENTOS000516v02'   # what ?Q answers; nil = refuse

        # Attach to the hub the file already describes, so that a test
        # can inspect what its subprocesses did; seed it otherwise.
        if @path && File.exist?(@path) then load
        else                                save
        end
    end

    # Build from the environment, for the executable's subprocesses.
    def self.from_env(env = ENV)
        new(path:     env['EXSYS_TEST_HUB'],
            lock:     env['EXSYS_TEST_LOCK'],
            delay:    env['EXSYS_TEST_DELAY'].to_f).tap do |hub|
            hub.silent   = !env['EXSYS_TEST_SILENT'].nil?
            hub.lockable =  env['EXSYS_TEST_NOLOCK'].nil?
            hub.garbage  =  env['EXSYS_TEST_GARBAGE']
        end
    end

    def state = (load; @state)
    def flash = (load; @flash)

    # Ports currently powered, as a sorted list -- the oracle the tests
    # compare against.
    def ports_on
        1.upto(16).select {|p| state & (1 << (p-1)) != 0 }
    end

    # The power-on state the hub would come back to.
    def flash_ports
        1.upto(16).select {|p| flash & (1 << (p-1)) != 0 }
    end

    # Record how the line was opened, so a test can check the library
    # asks for the device and the speed the hub actually needs.
    def opened(line, speed, mode)
        @line, @speed, @mode = line, speed, mode
        @opens += 1
    end

    # Called by each opened line before it locks.  The lock handle
    # itself belongs to the line, not to the hub, so that two threads
    # hold two of them and genuinely contend.
    def lock_attempted
        raise @lock_error            if @lock_error   # must NOT be swallowed
        raise Errno::ENOTSUP         unless @lockable # platform refusal
        @locks += 1
    end

    # Answer one command, as the hub would.
    def command(cmd)
        @log << cmd
        return ''       if @silent
        return @garbage if @garbage

        load
        reply = dispatch(cmd)
        save
        reply
    end

    private

    def dispatch(cmd)
        code = cmd[0, 2]
        args = cmd[2..].to_s

        # GP and ?Q are the two commands the hub answers without a
        # password, both with a bare payload rather than a G/E status.
        return encode(@state) + 'FFFF' if code == 'GP'
        return @ident || 'E01'         if code == '?Q'

        return 'E01' unless args.start_with?(@password)
        rest = args[@password.size..]

        sleep @delay if @delay.positive?

        case code
        when 'SP' then @state = decode(rest)             ; 'G'
        when 'FP' then @state = @flash = decode(rest)    ; 'G'
        when 'WP' then @flash = @state                   ; 'G'
        when 'RD' then @state = @flash = 0
                       @password = DEFAULT_PASSWORD            ; 'G'
        when 'RH' then @state = @flash                   ; nil
        when 'CP' then @password = rest                  ; 'G'
        else           'E02'
        end
    end

    # Little-endian 16-bit, spelled out rather than packed.  Upper case
    # because that is what a real hub answers -- observed on an ExSYS
    # 16-port unit, which replies to GP with e.g. "C4FFFFFF".
    def encode(v) = format('%02X%02X', v & 0xff, (v >> 8) & 0xff)
    def decode(s) = s[0, 2].to_i(16) | (s[2, 2].to_i(16) << 8)

    def load
        return if @path.nil? || !File.exist?(@path)
        @state, @flash, @password = File.read(@path).split("\n", 3)
        @state = @state.to_i(16)
        @flash = @flash.to_i(16)
    end

    def save
        return if @path.nil?
        File.write(@path, "%04x\n%04x\n%s" % [ @state, @flash, @password ])
    end
end
