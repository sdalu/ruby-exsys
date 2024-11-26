
Controlling a [ExSYS Managed USB hub][1] without being 
constrained by the official binary-only support.


Executable
~~~sh
dev=/dev/ttyU0 
exsys-hub -d ${dev} on                # All on
exsys-hub -d ${dev} off               # All off
exsys-hub -d ${dev} on 1 2            # Only turn on port 1 and 2
exsys-hub -d ${dev} toggle 3, 5       # Toggle port 3 and 5
exsys-hub -d ${dev} set 3:on 5:off    # Turn on port 3, turn off port 5
exsys-hub -d ${dev} -D false set 3:on # Turn on port 3, turn off all other ports
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






[1]: https://www.exsys-shop.de/shopware/en/categories/hubsdocks/usb-hubs-managed/1263/managed-16-port-usb-3.2-gen-1-metal-hub-with-15kv-esd-surge-protection-din-rail?c=35
