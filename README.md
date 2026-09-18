# exsys

Switch the ports of an [ExSYS managed USB hub][1] on and off, from the
shell or from Ruby, without being constrained by the vendor's
binary-only tool.

[![ExSYS EX-1526HMVS: managed 16-port USB 3.2 Gen 1 metal hub][hub]][1]


## How it works

The hub is driven over a serial line, not over USB: switching a port is
a serial command, and the data path is not involved.  Every command is
answered, and that reply is how the port state is read back and how a
refused command is reported.

~~~text
  ┌───────────────┐                            ┌─────────────────────┐
  │               │                            │                     │
  │     host      │                            │     EX-1526HMVS     │
  │               │  USB 3.2 (data)            │                     │
  │               │◂──────────────────────────▸│     UP-A / UP-B     │
  │               │                            │                     │
  │   exsys-usb   │  serial, 9600 8N1          │                     │
  │  (this gem)   │◂──────────────────────────▸│  management (FTDI)  │
  │               │                            │                     │
  │               │                            │  16 ports, 1 .. 16  │
  └───────────────┘                            └─────────────────────┘
~~~

The serial line is `/dev/ttyU0` on FreeBSD, `/dev/ttyUSB0` on Linux.
You need read and write access to it: the device is usually owned by a
group such as `dialout` or `plugdev`, so check `ls -l` on it and add
yourself to that group rather than reaching for `sudo`.

`exsys-usb discover` lists the lines that could be a hub, so you do not
have to guess which one it is.  See [Finding the hub](#finding-the-hub).

The hub answers only to its password, `pass` unless it has been
changed.  Port numbering starts at 1 and runs to however many ports
the hub reports having: the gem asks it, rather than assuming sixteen.


## Install

~~~sh
gem install exsys
~~~

The only runtime dependency is [uart][2], which pulls in `ruby-termios`
-- a C extension, so a compiler and the Ruby headers must be available
when it builds.

Tested on Ruby 3.1, 3.3 and 3.4, on FreeBSD and on Linux.


## Command line

~~~sh
dev=/dev/ttyU0
exsys-usb -d ${dev} on                # All on
exsys-usb -d ${dev} off               # All off
exsys-usb -d ${dev} on 1 2            # Only turn on port 1 and 2
exsys-usb -d ${dev} toggle 3, 5       # Toggle port 3 and 5
exsys-usb -d ${dev} set 3:on 5:off    # Turn on port 3, turn off port 5
exsys-usb -d ${dev} -D false set 3:on # Turn on port 3, all others off
exsys-usb -d ${dev} -c on 1           # Turn on port 1, and save to flash
~~~

### Actions

| Action              | Effect                                          |
| :------------------ | :---------------------------------------------- |
| `on [PORT...]`      | Power the listed ports, or every port           |
| `off [PORT...]`     | Unpower the listed ports, or every port         |
| `toggle [PORT...]`  | Invert the listed ports, or every port          |
| `set PORT:STATE...` | Set the listed ports; `-D` decides the rest     |
| `status [PORT...]`  | Report the ports, one `N on` / `N off` per line |
| `discover`          | List the lines that could be a hub              |
| `query`             | What the hub says it is: id, ports, firmware    |
| `commit`            | Save the current port state to flash            |
| `factory-reset`     | Factory reset; refuses without `--yes`          |
| `reset`             | Reboot the hub; refuses without `--yes`         |

> [!WARNING]
> `reset` and `factory-reset` both drop power to every port, so both
> refuse without `--yes`.  `reset` reboots the whole hub; it is not the
> way to power-cycle one device, which is `off` then `on`.
>
> `factory-reset` is not the inverse of `commit`.  It issues the hub's
> `RD` command: every port drops and the password goes back to `pass`.
> Nothing in the protocol reloads a saved state -- the hub applies it
> at power-on by itself.


A port state in `set` is written `PORT:STATE`, where `STATE` is one of
`1`, `on`, `ON`, `true`, `TRUE`, `t`, `T` or their false counterparts
`0`, `off`, `OFF`, `false`, `FALSE`, `f`, `F`.

### Options

| Option                | Meaning                                       |
| :-------------------- | :-------------------------------------------- |
| `-d`, `--device=DEV`  | Serial line to the hub (required, but see      |
|                       | `discover`)                                   |
| `-p`, `--password=STR`| Hub password; defaults to `pass`              |
| `-c`, `--commit`      | Also write the new state to flash             |
| `-y`, `--yes`         | Mean a destructive action                     |
| `-v`, `--verbose`     | Report the port states after a change         |
| `-D`, `--default=BOOL`| State for the ports `set` does not name       |
| `--debug[=FILE]`      | Trace the serial exchange to stderr, or FILE  |
| `-V`, `--version`     | Print the library version                     |
| `-h`, `--help`        | Print the usage                               |

The debug trace shows every frame sent and received, with the password
blanked out; when it is written to a file, that file is created
readable only by you.

`status` prints one port per line, which greps and awks without
parsing:

~~~sh
exsys-usb -d ${dev} status            # every port
exsys-usb -d ${dev} status 3 7        # just those two
exsys-usb -d ${dev} -v on 3           # switch, then report
~~~

### Exit status

`0` when the command was carried out, `1` otherwise -- a malformed
argument, a port outside 1..16, an unreachable serial line, or a
command the hub refused.  The error goes to stderr, so a script can
rely on the status:

~~~sh
exsys-usb -d /dev/ttyU0 off 3 || echo "could not switch port 3 off"
~~~


## Finding the hub

The management side of the hub is an ordinary FTDI FT232, so the host
can be asked which serial lines are attached and what their serial
numbers are:

~~~sh
exsys-usb discover
~~~

~~~text
/dev/ttyUSB0 A50285BI 1-1.2.4.4
/dev/ttyUSB1 -        1-1.3
~~~

One line per adapter: the device to pass to `-d`, the FT232's own
serial number, and where it sits in the USB tree.  A `-` is a name this
host cannot give — an EEPROM carrying no serial, or a topology that
could not be established.  The same list from Ruby:

~~~ruby
ExSYS::ManagedUSB.available
# => [ { :device => "/dev/ttyUSB0", :serial => "A50285BI",
#        :usb_path => "1-1.2.4.4" },
#      { :device => "/dev/ttyUSB1", :serial => nil,
#        :usb_path => "1-1.3" } ]
~~~

**A candidate is not a hub.**  That FT232 is not an ExSYS part and
carries no ExSYS id, so this lists every FT232 on the host — a
USB-serial cable, a debug probe, a second hub — and nothing short of
opening the line and asking (`?Q`, the `query` action) tells them
apart.  Opening an unknown line means writing to somebody else's
device, which is why this reports rather than decides.  A program that
switches ports should not pick one silently when there is more than
one: the ports of an unrelated hub exist, accept the frames, and report
success.

**Write down a serial or a path, not the line.**  The number in
`/dev/ttyUSB1` is neither the hub's nor the USB device number: it is
the usbserial (Linux) or ucom (FreeBSD) layer's own index, and it is
the lowest one free when that adapter is probed.  So it depends on what
else attached first, and it is reused — unplug whatever holds
`ttyUSB0` and the next thing to attach takes `ttyUSB0`.  Two hubs can
swap lines across a reboot, or while the machine is up.

The other two are stable, in different ways, and which one is wanted
depends on the question:

| Name       | Stays with          | Answers                          |
| :--------- | :------------------ | :------------------------------- |
| `:serial`  | the adapter         | "this particular hub"            |
| `:usb_path`| the socket          | "whatever is plugged in there"   |

Move a hub to another port and its serial goes with it while its path
changes; swap in a replacement hub and the path is unchanged while the
serial is not.  For naming one particular hub the serial is the answer.
The path is for a hub whose EEPROM carries no serial to be named by,
and for a bench where the socket is the fixed thing.

Both platforms report a path, by different means.  Linux states it, in
`/sys`.  FreeBSD states nothing of the kind, so it is walked out of the
sysctl tree: each device's `%location` gives the port it occupies on
its parent and `%parent` names that parent, so collecting the ports
from the adapter up to the root hub builds the same shape.  The
numbering is each host's own, though — FreeBSD counts buses from 0 and
Linux from 1 — so a path names a socket on the machine that reported
it and does not travel to another.

Discovery reads `/sys/class/tty` through `udevadm` on Linux and
`dev.uftdi` through `sysctl` on FreeBSD; any other platform raises
rather than answering an empty list, an empty list being a claim that
nothing is attached.


## Library

~~~ruby
# Instantiate the hub (Linux: ttyUSB?, FreeBSD: ttyU?)
# and enable debug output to stderr
hub = ExSYS::ManagedUSB.new('/dev/ttyU0', debug: STDERR)

# Chain turning on every port, then switch off ports 4, 5 and 6
hub.on(:all).off(4,5,6)

# Toggle each port in turn
hub.ports.each do |p|
    hub.toggle(p)
end

# Set the state of ports 1 and 2
hub.set({ 1 => true, 2 => false })

# Set ports 1 and 2, forcing every other port off
hub.set({ 1 => true, 2 => true }, false)
~~~

Reading the state back has no command-line equivalent; it is a library
call, and answers in whichever shape suits the caller:

~~~ruby
hub.get           # => { 1 => true, 2 => false, ... }
hub.get(:on_off)  # => { :on => [1, 3], :off => [2, 4, ...] }
hub.get(:on)      # => [ 1, 3 ]
hub.get(:off)     # => [ 2, 4, ... ]
~~~

`on`, `off` and `toggle` want an explicit port list, and `:all` is how
you say every port.  An empty list is refused rather than read as
"all": `hub.off(*ports)` with an empty `ports` is the very same call as
`hub.off`, so a computed list that came back empty would otherwise
switch all sixteen.  The command line is unaffected -- naming no port
there still means every port.

Switching is a read-modify-write, and the library holds the serial
line -- locked -- across the whole exchange, so two processes driving
the same hub cannot lose each other's changes.

A read-decide-write spans two calls, so it needs the line held across
both.  Wrap them in a session:

~~~ruby
hub.session do
    hub.on(1) unless hub.get[1]
end
~~~

The hub will also describe itself, over the same line and without a
password:

~~~ruby
hub.query       # => { id: "CENTOS", ports: 16, firmware: "v02",
                #      raw: "CENTOS000516v02" }
hub.port_count  # => 16, asked once and remembered
~~~

`:all` covers exactly those ports, and a port the hub does not have is
refused.  The count is read from the same field the vendor's own tool
reads, checked against it for hubs reporting 4, 8, 16 and 32 ports.

It is asked once and kept for the life of the object, which outlasts
any one connection -- the serial line is opened per operation, not
held.  So a hub object is bound to the hub it first asked.  If the
device is unplugged and another appears under the same name, build a
new one; nothing in the library can notice the swap.

`hub.factory_reset(confirm: true)` issues `RD` and carries the warning
above.  The keyword is required: it is the one operation here that
nothing undoes, and the one most easily reached by misunderstanding.
It was called `restore` up to 0.6; the old name now raises rather than
run.  The hub's password goes back to `pass`, and the object follows it
there, so it stays usable afterwards -- but a later run of the tool
against that hub must drop its `-p`.

Sessions nest, so the methods above stay correct when called inside
one, and a session belongs to the thread that opened it: another thread
opens, and locks, its own line.  The wire protocol is documented in the
`ExSYS::ManagedUSB` class comment.


## Tests

~~~sh
rake test          # or: ruby -Itest test/test_managed_usb.rb
~~~

The suite drives the library and the executable against a model of the
hub's serial protocol (`test/support/`), so it needs neither a hub nor
the `uart`/`termios` gems.


## License

MIT, see [LICENSE](LICENSE).


[1]:   https://www.exsys.de/en/managed-16-port-usb-3.2-gen-1-metal-hub-with-15kv-esd-surge-protection-din-rail/EX-1526HMVS
[2]:   https://rubygems.org/gems/uart
[hub]: https://www.exsys.de/thumbnail/df/a9/63/1716816684/EX-1526HMVS_-_Managed_16-Port_USB_3.2_Gen_1_Metall_HUB_15KV_ESD-1_800x800.jpg
