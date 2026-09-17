
Controlling a [ExSYS Managed USB hub][1] (EX-1526HMVS) without being 
constrained by the official binary-only support.

[![ExSYS EX-1526HMVS: managed 16-port USB 3.2 Gen 1 metal hub][hub]][1]


Executable
~~~sh
dev=/dev/ttyU0 
exsys-usb -d ${dev} on                # All on
exsys-usb -d ${dev} off               # All off
exsys-usb -d ${dev} on 1 2            # Only turn on port 1 and 2
exsys-usb -d ${dev} toggle 3, 5       # Toggle port 3 and 5
exsys-usb -d ${dev} set 3:on 5:off    # Turn on port 3, turn off port 5
exsys-usb -d ${dev} -D false set 3:on # Turn on port 3, turn off all other ports
~~~

Library:

~~~ruby
# Instanciate hub (Linux: ttyUSB?, FreeBSD: ttyU?)
# and enable debug output to stderr
hub = ExSYS::ManagedUSB.new('/dev/ttyU0', debug: STDERR)

# Chaining turning on all port, and swithing off ports 4,5,6
hub.on.off(4,5,6)

# Perform sequential toggle of all individual ports
ExSYS::ManagedUSB::PORTS.each do |p|
    hub.toggle(p)
end

# Set ports states for 1 and 2
hub.set({ 1 => true, 2 => false })

# Set ports states for 1 and 2, forcing other ports to off
hub.set({ 1 => true, 2 => true }, false)
~~~


Tests
~~~sh
rake test          # or: ruby -Itest test/test_managed_usb.rb
~~~

The suite drives the library and the executable against a model of the
hub's serial protocol (`test/support/`), so it needs neither a hub nor
the `uart`/`termios` gems.



[1]:   https://www.exsys.de/en/managed-16-port-usb-3.2-gen-1-metal-hub-with-15kv-esd-surge-protection-din-rail/EX-1526HMVS
[hub]: https://www.exsys.de/thumbnail/df/a9/63/1716816684/EX-1526HMVS_-_Managed_16-Port_USB_3.2_Gen_1_Metall_HUB_15KV_ESD-1_800x800.jpg
