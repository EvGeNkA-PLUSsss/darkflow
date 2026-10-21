// Package anet is a drop-in, non-cgo replacement for github.com/wlynxg/anet.
//
// WHY THIS FILE EXISTS
//
// Upstream anet v0.0.5 (the newest release; its last commit only touched
// README.md) supports Android by reaching into the standard library with
//
//	//go:linkname zoneCache net.zoneCache
//	//go:linkname zoneCacheX golang.org/x/net/internal/socket.zoneCache
//
// and then calling methods on that value directly. Go's linker rejects the
// reference outright on every toolchain that can build the Tor PT clients:
//
//	link: github.com/wlynxg/anet: invalid reference to net.zoneCache
//
// That was reproduced here with go1.23.4, go1.25.12 and go1.27.2, for
// GOOS=android GOARCH=arm64. snowflake needs >= 1.25.12 and lyrebird needs
// >= 1.26.0, so no available toolchain avoids it, and because the target
// platforms include Android there is no build tag that selects the plain
// pass-through file instead.
//
// WHAT THIS PACKAGE DOES
//
// It provides the same package name and the same exported functions as anet,
// implemented by delegating to the standard library's net package - which is
// exactly what upstream anet itself does on every non-Android platform (see its
// interface.go, guarded by `//go:build !android`). The only callers in these
// binaries are github.com/pion/transport/{v2,v3,v4}/stdnet, and they use
// exactly two functions: Interfaces and InterfaceAddrsByInterface.
//
// The netlink RIB parsing helpers are reimplemented here in pure Go as working
// code (not stubs) so the exported surface matches upstream, but no caller in
// these binaries uses them; the interface enumeration is pure `net.*`.
//
// CONSEQUENCE, STATED PLAINLY
//
// The Android-specific netlink workaround in upstream anet is NOT present. On
// Android, interface enumeration therefore uses the standard library's
// getifaddrs-based implementation instead. That is a deliberate, reviewed
// substitution recorded in jniLibs/PT_SOURCES.json, not an upstream build.
package anet

import (
	"net"
	"syscall"
	"unsafe"
)

// SetAndroidVersion is retained for API compatibility with upstream anet. This
// implementation does not need an API level because it does not use any
// API-level-dependent code path, so it is intentionally a no-op.
func SetAndroidVersion(version uint) {}

// Interfaces returns a list of the system's network interfaces.
func Interfaces() ([]net.Interface, error) {
	return net.Interfaces()
}

// InterfaceAddrs returns a list of the system's unicast interface addresses.
//
// The returned list does not identify the associated interface; use Interfaces
// and Interface.Addrs for more detail.
func InterfaceAddrs() ([]net.Addr, error) {
	return net.InterfaceAddrs()
}

// InterfaceAddrsByInterface returns a list of the system's unicast interface
// addresses by specific interface.
func InterfaceAddrsByInterface(ifi *net.Interface) ([]net.Addr, error) {
	return ifi.Addrs()
}

// ---------------------------------------------------------------------------
// Netlink RIB parsing, matching upstream anet's exported surface.
//
// These are self-contained: unlike upstream they name no unexported standard
// library symbol, so no //go:linkname is involved anywhere in this package.
// ---------------------------------------------------------------------------

// nlmAlignOf rounds the length of a netlink message up to align it properly.
func nlmAlignOf(msglen int) int {
	return (msglen + syscall.NLMSG_ALIGNTO - 1) & ^(syscall.NLMSG_ALIGNTO - 1)
}

// rtaAlignOf rounds the length of a netlink route attribute up to align it
// properly.
func rtaAlignOf(attrlen int) int {
	return (attrlen + syscall.RTA_ALIGNTO - 1) & ^(syscall.RTA_ALIGNTO - 1)
}

// NetlinkRouteRequest represents a request message to receive routing and link
// states from the kernel.
type NetlinkRouteRequest struct {
	Header syscall.NlMsghdr
	Data   syscall.RtGenmsg
}

func (rr *NetlinkRouteRequest) toWireFormat() []byte {
	b := make([]byte, rr.Header.Len)
	*(*uint32)(unsafe.Pointer(&b[0:4][0])) = rr.Header.Len
	*(*uint16)(unsafe.Pointer(&b[4:6][0])) = rr.Header.Type
	*(*uint16)(unsafe.Pointer(&b[6:8][0])) = rr.Header.Flags
	*(*uint32)(unsafe.Pointer(&b[8:12][0])) = rr.Header.Seq
	*(*uint32)(unsafe.Pointer(&b[12:16][0])) = rr.Header.Pid
	b[16] = byte(rr.Data.Family)
	return b
}

func newNetlinkRouteRequest(proto, seq, family int) []byte {
	rr := &NetlinkRouteRequest{}
	rr.Header.Len = uint32(syscall.NLMSG_HDRLEN + syscall.SizeofRtGenmsg)
	rr.Header.Type = uint16(proto)
	rr.Header.Flags = syscall.NLM_F_DUMP | syscall.NLM_F_REQUEST
	rr.Header.Seq = uint32(seq)
	rr.Data.Family = uint8(family)
	return rr.toWireFormat()
}

// NetlinkRIB returns the routing information base, as known as RIB, which
// consists of network facility information, states and parameters.
func NetlinkRIB(proto, family int) ([]byte, error) {
	s, err := syscall.Socket(syscall.AF_NETLINK, syscall.SOCK_RAW|syscall.SOCK_CLOEXEC, syscall.NETLINK_ROUTE)
	if err != nil {
		return nil, err
	}
	defer syscall.Close(s)
	sa := &syscall.SockaddrNetlink{Family: syscall.AF_NETLINK}

	wb := newNetlinkRouteRequest(proto, 1, family)
	if err := syscall.Sendto(s, wb, 0, sa); err != nil {
		return nil, err
	}
	lsa, err := syscall.Getsockname(s)
	if err != nil {
		return nil, err
	}
	lsanl, ok := lsa.(*syscall.SockaddrNetlink)
	if !ok {
		return nil, syscall.EINVAL
	}
	var tab []byte
	rbNew := make([]byte, syscall.Getpagesize())
done:
	for {
		rb := rbNew
		nr, _, err := syscall.Recvfrom(s, rb, 0)
		if err != nil {
			return nil, err
		}
		if nr < syscall.NLMSG_HDRLEN {
			return nil, syscall.EINVAL
		}
		rb = rb[:nr]
		tab = append(tab, rb...)
		msgs, err := ParseNetlinkMessage(rb)
		if err != nil {
			return nil, err
		}
		for _, m := range msgs {
			if m.Header.Seq != 1 || m.Header.Pid != lsanl.Pid {
				return nil, syscall.EINVAL
			}
			if m.Header.Type == syscall.NLMSG_DONE {
				break done
			}
			if m.Header.Type == syscall.NLMSG_ERROR {
				return nil, syscall.EINVAL
			}
		}
	}
	return tab, nil
}

// NetlinkMessage represents a netlink message.
type NetlinkMessage struct {
	Header syscall.NlMsghdr
	Data   []byte
}

// ParseNetlinkMessage parses b as an array of netlink messages and returns the
// slice containing the NetlinkMessage structures.
func ParseNetlinkMessage(b []byte) ([]NetlinkMessage, error) {
	var msgs []NetlinkMessage
	for len(b) >= syscall.NLMSG_HDRLEN {
		h, dbuf, dlen, err := netlinkMessageHeaderAndData(b)
		if err != nil {
			return nil, err
		}
		m := NetlinkMessage{Header: *h, Data: dbuf[:int(h.Len)-syscall.NLMSG_HDRLEN]}
		msgs = append(msgs, m)
		b = b[dlen:]
	}
	return msgs, nil
}

func netlinkMessageHeaderAndData(b []byte) (*syscall.NlMsghdr, []byte, int, error) {
	h := (*syscall.NlMsghdr)(unsafe.Pointer(&b[0]))
	l := nlmAlignOf(int(h.Len))
	if int(h.Len) < syscall.NLMSG_HDRLEN || l > len(b) {
		return nil, nil, 0, syscall.EINVAL
	}
	return h, b[syscall.NLMSG_HDRLEN:], l, nil
}

// NetlinkRouteAttr represents a netlink route attribute.
type NetlinkRouteAttr struct {
	Attr  syscall.RtAttr
	Value []byte
}

// ParseNetlinkRouteAttr parses m's payload as an array of netlink route
// attributes and returns the slice containing the NetlinkRouteAttr structures.
func ParseNetlinkRouteAttr(m *NetlinkMessage) ([]NetlinkRouteAttr, error) {
	var b []byte
	switch m.Header.Type {
	case syscall.RTM_NEWLINK, syscall.RTM_DELLINK:
		b = m.Data[syscall.SizeofIfInfomsg:]
	case syscall.RTM_NEWADDR, syscall.RTM_DELADDR:
		b = m.Data[syscall.SizeofIfAddrmsg:]
	case syscall.RTM_NEWROUTE, syscall.RTM_DELROUTE:
		b = m.Data[syscall.SizeofRtMsg:]
	default:
		return nil, syscall.EINVAL
	}
	var attrs []NetlinkRouteAttr
	for len(b) >= syscall.SizeofRtAttr {
		a, vbuf, alen, err := netlinkRouteAttrAndValue(b)
		if err != nil {
			return nil, err
		}
		ra := NetlinkRouteAttr{Attr: *a, Value: vbuf[:int(a.Len)-syscall.SizeofRtAttr]}
		attrs = append(attrs, ra)
		b = b[alen:]
	}
	return attrs, nil
}

func netlinkRouteAttrAndValue(b []byte) (*syscall.RtAttr, []byte, int, error) {
	a := (*syscall.RtAttr)(unsafe.Pointer(&b[0]))
	if int(a.Len) < syscall.SizeofRtAttr || int(a.Len) > len(b) {
		return nil, nil, 0, syscall.EINVAL
	}
	return a, b[syscall.SizeofRtAttr:], rtaAlignOf(int(a.Len)), nil
}
