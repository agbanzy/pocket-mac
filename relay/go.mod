module github.com/innoedge/pocketmac-relay

// Floor raised deliberately, not incidentally. govulncheck against 1.25.6 reported NINE standard
// library vulnerabilities this code actually calls — every one reachable through ListenAndServeTLS
// and the websocket accept path, i.e. the live internet-facing surface. The worst sat in crypto/tls
// (GO-2026-4337 unexpected session resumption, fixed in 1.25.7; GO-2026-5856 Encrypted Client Hello
// privacy leak, fixed in 1.25.12) with several more in crypto/x509. Nothing in this module was at
// fault; the toolchain was. With GOTOOLCHAIN=auto this directive makes the build fetch a fixed
// compiler rather than quietly using whatever happens to be installed. Do not lower it.
go 1.25.12

require github.com/coder/websocket v1.8.15
