
Controlling a [ExSYS Managed USB hub][1] without being 
constrained by the official binary-only support.

~~~ruby
hub = ExSYS::ManagedUSB.new('/dev/ttyU0', debug: STDERR)

hub.on.off(4,5,6)

ExSYS::ManagedUSB::PORTS.each do |p|
    hub.toggle(p)
end
~~~


[1]: https://www.exsys-shop.de/shopware/en/categories/hubsdocks/usb-hubs-managed/1263/managed-16-port-usb-3.2-gen-1-metal-hub-with-15kv-esd-surge-protection-din-rail?c=35
