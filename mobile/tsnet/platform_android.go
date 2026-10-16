package tailnet

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"strings"

	"tailscale.com/net/netmon"
)

// Interfaces is implemented in Kotlin. Android restricts Go's netlink interface
// enumeration; Java NetworkInterface works without creating a VpnService.
type Interfaces interface{ Snapshot() (string, error) }

// Initialize must run once, before Start. The application owns the callback and
// the private directory for the lifetime of the Go runtime.
func Initialize(directory string, source Interfaces) error {
	if err := os.MkdirAll(directory, 0700); err != nil {
		return err
	}
	for _, key := range []string{"HOME", "TMPDIR", "TS_LOGS_DIR"} {
		if err := os.Setenv(key, directory); err != nil {
			return err
		}
	}
	netmon.RegisterInterfaceGetter(func() ([]netmon.Interface, error) {
		snapshot, err := source.Snapshot()
		if err != nil {
			return nil, err
		}
		var records []struct {
			Name      string
			Index     int
			MTU       int
			Up        bool
			Loopback  bool
			Addresses []string
		}
		if err := json.Unmarshal([]byte(snapshot), &records); err != nil {
			return nil, err
		}
		result := make([]netmon.Interface, 0, len(records))
		for _, record := range records {
			flags := net.Flags(0)
			if record.Up {
				flags |= net.FlagUp | net.FlagRunning
			}
			if record.Loopback {
				flags |= net.FlagLoopback
			}
			iface := netmon.Interface{Interface: &net.Interface{Name: record.Name, Index: record.Index, MTU: record.MTU, Flags: flags}, AltAddrs: []net.Addr{}}
			for _, address := range record.Addresses {
				ipText, _, _ := strings.Cut(address, "/")
				if rawIP, zone, scoped := strings.Cut(ipText, "%"); scoped {
					ip := net.ParseIP(rawIP)
					if ip == nil {
						return nil, fmt.Errorf("invalid scoped interface address")
					}
					iface.AltAddrs = append(iface.AltAddrs, &net.IPAddr{IP: ip, Zone: zone})
					continue
				}
				ip, network, err := net.ParseCIDR(address)
				if err != nil {
					return nil, fmt.Errorf("invalid interface address")
				}
				network.IP = ip
				iface.AltAddrs = append(iface.AltAddrs, network)
			}
			result = append(result, iface)
		}
		return result, nil
	})
	return nil
}
