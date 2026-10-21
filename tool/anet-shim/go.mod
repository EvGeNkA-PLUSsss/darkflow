// Package anet is a drop-in, non-cgo replacement for github.com/wlynxg/anet.
//
// See anet.go in this directory for the full rationale. In short: upstream anet
// v0.0.5 supports Android by using //go:linkname to address the unexported
// standard-library symbol net.zoneCache, which the Go linker rejects
//
//	link: github.com/wlynxg/anet: invalid reference to net.zoneCache
//
// on go1.23.4, go1.25.12 and go1.27.2 alike, so it cannot be linked into an
// Android/arm64 binary with any toolchain that satisfies snowflake (>= 1.25.12)
// or lyrebird (>= 1.26.0).
//
// This module keeps the same import path so that `replace` can redirect
// github.com/wlynxg/anet to it, and the same exported API, implemented by
// delegating to the standard library's net package - which is exactly what
// upstream anet does on every non-Android platform.
module github.com/wlynxg/anet

go 1.21
