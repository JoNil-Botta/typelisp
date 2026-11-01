(import stdlib.byte_buf)
(import stdlib.fs)
(import stdlib.io)
(import stdlib.net.dns_name as names)
(import stdlib.net.ip)
(import stdlib.net.resolver_config as config)
(import stdlib.net.resolver_config_linux as linux)
(import stdlib.profile)
(import stdlib.str_cat)
(import stdlib.test)

(define (name-checks) : unit
  (let
    [source : String "MiXeD.Example."]
    (match (names.parse (& source))
      [(DnsNameErr _) (io.panic "valid rooted name")]
      [(DnsNameOk name)
        (test.assert-string-eq
          (names.text (& name))
          "mixed.example"
          "lowercase")
        (test.assert-true (names.rooted? (& name)) "rooted identity")
        (test.assert-i64-eq (names.wire-length (& name)) 15 "wire length")]))
  (let
    [source : String "a..b"]
    (match (names.parse (& source))
      [(DnsNameOk _) (io.panic "empty label accepted")]
      [(DnsNameErr error) (test.assert-i64-eq error.offset 2 "original offset")]))
  (let
    [source : String "x.LOCALHOST."]
    (match (names.parse (& source))
      [(DnsNameErr _) (io.panic "localhost name")]
      [(DnsNameOk name)
        (test.assert-true (names.localhost? (& name)) "localhost policy")])))

(define (repeat-text [text : (& text str)] [count : i64]) : String
  (let
    [out : byte_buf.ByteBuf (byte_buf.new)]
    [index : i64 0]
    (while (< index count)
      (set! out (byte_buf.append-bytes out (byte_buf.str-as-bytes text)))
      (set! index (+ index 1)))
    (byte_buf.to-string out)))

(define (expect-name-error [source : String] [offset : i64]) : unit
  (match (names.parse (& source))
    [(DnsNameOk _) (io.panic "invalid name accepted")]
    [(DnsNameErr error)
      (test.assert-i64-eq error.offset offset "name error offset")]))

(define (name-boundary-checks) : unit
  (expect-name-error "" 0)
  (expect-name-error "." 0)
  (expect-name-error "a.." 2)
  (expect-name-error "a_b" 1)
  (expect-name-error "-a" 0)
  (expect-name-error "a-.b" 1)
  (expect-name-error "éxample" 0)
  (expect-name-error "a b" 1)
  (expect-name-error (repeat-text "a" 64) 63)
  (expect-name-error (repeat-text "a" 255) 254)
  (let
    [label : String (repeat-text "a" 63)]
    [source : String
      (str_cat.str-cat
        (clone label)
        "."
        (clone label)
        "."
        label
        "."
        (repeat-text "b" 61))]
    (match (names.parse (& source))
      [(DnsNameErr _) (io.panic "253-byte name rejected")]
      [(DnsNameOk name)
        (test.assert-i64-eq (names.wire-length (& name)) 255 "max wire")]))
  (let
    [source : String (str_cat.str-cat (repeat-text "a." 126) "a.")]
    (match (names.parse (& source))
      [(DnsNameErr _) (io.panic "127 labels rejected")]
      [(DnsNameOk name)
        (test.assert-i64-eq (names.label-count (& name)) 127 "max labels")]))
  (let
    [rooted : String "a."]
    [relative : String "A"]
    (match (names.parse (& rooted))
      [(DnsNameErr _) (io.panic "rooted")]
      [(DnsNameOk a)
        (match (names.parse (& relative))
          [(DnsNameErr _) (io.panic "relative")]
          [(DnsNameOk b)
            (test.assert-true
              (not (names.equal? (& a) (& b)))
              "rooted identity distinct")])]))
  (let
    [source : String "notlocalhost"]
    (match (names.parse (& source))
      [(DnsNameErr _) (io.panic "name")]
      [(DnsNameOk name)
        (test.assert-true
          (not (names.localhost? (& name)))
          "localhost boundary")]))
  (let
    [source : byte_buf.ByteBuf
      (byte_buf.push (byte_buf.append-string (byte_buf.new) "ok") 0)]
    (match (names.parse-bytes (byte_buf.as-bytes (& source)))
      [(DnsNameOk _) (io.panic "NUL accepted")]
      [(DnsNameErr error) (test.assert-i64-eq error.offset 2 "NUL byte offset")])))

(define (kind-code [kind : config.ConfigErrorKind]) : i64
  (match kind
    [(ConfigFileTooLarge) 1]
    [(ConfigLineTooLong) 2]
    [(ConfigTooManyRecords) 3]
    [(ConfigTooManyAliases) 4]
    [(ConfigTooManyBindings) 5]
    [(ConfigTooManyServers) 6]
    [(ConfigTooManySuffixes) 7]
    [(ConfigSuffixWireLimit) 8]
    [(ConfigMalformedDirective) 9]
    [(ConfigInvalidAddress _) 10]
    [(ConfigInvalidName _) 11]
    [(ConfigInvalidPort) 12]
    [(ConfigInvalidScope) 13]
    [(ConfigInvalidTimeout) 14]
    [(ConfigUnavailable) 15]))

(define (expect-host-error [source : String] [kind : i64] [line : i64]) : unit
  (match (config.parse-hosts (byte_buf.str-as-bytes (& source)))
    [(HostsSnapshotOk _) (io.panic "invalid hosts accepted")]
    [(HostsSnapshotErr error)
      (test.assert-i64-eq (kind-code error.kind) kind "hosts category")
      (test.assert-i64-eq error.line line "hosts line")
      (test.assert-string-eq
        (& (config.source-path error.source))
        "/etc/hosts"
        "hosts path")]))

(define (expect-resolv-error [source : String] [kind : i64] [line : i64]) : unit
  (match (config.parse-linux
    (byte_buf.str-as-bytes "")
    (byte_buf.str-as-bytes (& source)))
    [(ResolverConfigOk _) (io.panic "invalid resolver input accepted")]
    [(ResolverConfigErr error)
      (test.assert-i64-eq (kind-code error.kind) kind "resolv category")
      (test.assert-i64-eq error.line line "resolv line")
      (test.assert-string-eq
        (& (config.source-path error.source))
        "/etc/resolv.conf"
        "resolv path")]))

(define (parser-boundary-checks) : unit
  (expect-host-error "# first\n01.2.3.4 name" 10 2)
  (expect-host-error "::1 name_bad" 11 1)
  (expect-host-error "::1" 9 1)
  (expect-host-error "::1 a b c d e f g h i j k l m n o p q r" 4 1)
  (expect-host-error (repeat-text "::1 a\n" 4097) 3 4097)
  (expect-host-error
    (repeat-text "::1 a b c d e f g h i j k l m n o p q\n" 964)
    5
    964)
  (expect-host-error (repeat-text "#" 8193) 2 1)
  (expect-host-error (repeat-text "#" 1048577) 1 0)
  (expect-resolv-error "nameserver\n" 9 1)
  (expect-resolv-error "nameserver ::1 extra\n" 9 1)
  (expect-resolv-error "nameserver fe80::1%2\n" 10 1)
  (expect-resolv-error "domain\n" 9 1)
  (expect-resolv-error "domain a b\n" 9 1)
  (expect-resolv-error "search a b c d e f g\n" 7 1)
  (expect-resolv-error "search a..b\n" 11 1)
  (expect-resolv-error
    "nameserver ::1\nnameserver ::2\nnameserver ::3\nnameserver ::4\nnameserver ::5\nnameserver ::6\nnameserver ::7\nnameserver ::8\nnameserver ::9"
    6
    9)
  (let
    [large : String (repeat-text "a" 63)]
    [suffix : String
      (str_cat.str-cat
        (clone large)
        "."
        (clone large)
        "."
        large
        "."
        (repeat-text "b" 61))]
    (expect-resolv-error (str_cat.str-cat "search " suffix " a") 8 1))
  (let
    [source : String (repeat-text "#x\n" 349525)]
    [exact : String (str_cat.str-cat source "#")]
    (match (config.parse-hosts (byte_buf.str-as-bytes (& exact)))
      [(HostsSnapshotErr _) (io.panic "exact file bound rejected")]
      [(HostsSnapshotOk hosts)
        (test.assert-i64-eq (config.binding-count (& hosts)) 0 "exact 1 MiB")]))
  (let
    [exact : String (str_cat.str-cat (repeat-text "#" 8192) "\r\n")]
    (match (config.parse-hosts (byte_buf.str-as-bytes (& exact)))
      [(HostsSnapshotErr _) (io.panic "exact CRLF line bound rejected")]
      [(HostsSnapshotOk _) unit]))
  (let
    [source : String (repeat-text "::1 a\n" 4096)]
    (match (config.parse-hosts (byte_buf.str-as-bytes (& source)))
      [(HostsSnapshotErr _) (io.panic "4096 records rejected")]
      [(HostsSnapshotOk hosts)
        (test.assert-i64-eq
          (config.binding-count (& hosts))
          1
          "dedup after record cap")]))
  (let
    [source : String (repeat-text "options ndots:15\n" 100)]
    (match (config.parse-linux
      (byte_buf.str-as-bytes "")
      (byte_buf.str-as-bytes (& source)))
      [(ResolverConfigErr _) (io.panic "unknown directives")]
      [(ResolverConfigOk snapshot)
        (test.assert-i64-eq
          (config.diagnostic-count (& snapshot))
          64
          "bounded diagnostics")
        (test.assert-i64-eq
          (config.ignored-directive-count (& snapshot))
          100
          "total diagnostics")
        (test.assert-i64-eq
          (config.server-count (& snapshot))
          0
          "no ambient default server")])))

(define (explicit-checks) : unit
  (let
    [address : ip.IpAddr (V6 (ip.ipv6 0xfe80 0 0 0 0 0 0 1))]
    [servers : (Array config.Nameserver 4)
      (array
        (config.Nameserver (clone address) 1053 7)
        (config.Nameserver (clone address) 53 7)
        (config.Nameserver (clone address) 1053 8)
        (config.Nameserver address 1053 7))]
    [suffixes : (Array String 2) (array "EXAMPLE." "Second.example")]
    [values : (Array i64 4) (array 1 1000 29999 30000)]
    [index : i64 0]
    (while (< index 4)
      (match (config.from-explicit
        (slice-view servers 0 4)
        (slice-view suffixes 0 2)
        (byte_buf.str-as-bytes "::1 host")
        (array-ref values index))
        [(ResolverConfigErr _) (io.panic "valid explicit config")]
        [(ResolverConfigOk snapshot)
          (test.assert-i64-eq
            (config.server-count (& snapshot))
            3
            "tuple dedup")
          (let
            [first : (& snapshot config.Nameserver)
              (config.server-ref (& snapshot) 0)]
            (test.assert-i64-eq (cast first.port : i64) 1053 "explicit port")
            (test.assert-i64-eq (cast first.scope-id : i64) 7 "scope preserved"))
          (test.assert-i64-eq
            (config.attempt-timeout-ms (& snapshot))
            (array-ref values index)
            "timeout roundtrip")])
      (set! index (+ index 1)))
    (set! index 0)
    (while (< index 2)
      (match (config.from-explicit
        (slice-view servers 0 4)
        (slice-view suffixes 0 2)
        (byte_buf.str-as-bytes "")
        (if (= index 0)
          0
          30001))
        [(ResolverConfigOk _) (io.panic "invalid timeout")]
        [(ResolverConfigErr error)
          (test.assert-i64-eq (kind-code error.kind) 14 "timeout error")])
      (set! index (+ index 1))))
  (match (config.nameserver (V4 (ip.ipv4 127 0 0 1)) 53 1)
    [(NameserverOk _) (io.panic "IPv4 scope")]
    [(NameserverErr error)
      (test.assert-i64-eq (kind-code error.kind) 13 "scope error")])
  (match (config.nameserver (V4 (ip.ipv4 127 0 0 1)) 0 0)
    [(NameserverOk _) (io.panic "zero port")]
    [(NameserverErr error)
      (test.assert-i64-eq (kind-code error.kind) 12 "port error")]))

(define (exact-limit-checks) : unit
  (let
    [source : String (repeat-text "::1 a b c d\n" 4096)]
    (match (config.parse-hosts (byte_buf.str-as-bytes (& source)))
      [(HostsSnapshotErr _) (io.panic "16384 input bindings rejected")]
      [(HostsSnapshotOk hosts)
        (test.assert-i64-eq
          (config.binding-count (& hosts))
          4
          "binding limit inclusive")]))
  (let
    [source : String
      "nameserver ::1\nnameserver ::2\nnameserver ::3\nnameserver ::4\nnameserver ::5\nnameserver ::6\nnameserver ::7\nnameserver ::8\nsearch a b c d e f"]
    (match (config.parse-linux
      (byte_buf.str-as-bytes "::1 a b c d e f g h i j k l m n o p q")
      (byte_buf.str-as-bytes (& source)))
      [(ResolverConfigErr _) (io.panic "inclusive aliases/server/suffix caps")]
      [(ResolverConfigOk snapshot)
        (test.assert-i64-eq
          (config.server-count (& snapshot))
          8
          "eight servers")
        (test.assert-i64-eq (config.suffix-count (& snapshot)) 6 "six suffixes")
        (let
          [server : (& snapshot config.Nameserver)
            (config.server-ref (& snapshot) 7)]
          (test.assert-string-eq
            (& (ip.ip-to-string (& server.address)))
            "::8"
            "server order")
          (test.assert-i64-eq (cast server.port : i64) 53 "system port")
          (test.assert-i64-eq (cast server.scope-id : i64) 0 "system scope"))]))
  (let
    [label : String (repeat-text "a" 63)]
    [suffix : String
      (str_cat.str-cat
        (clone label)
        "."
        (clone label)
        "."
        label
        "."
        (repeat-text "b" 59))]
    [source : String (str_cat.str-cat "search " suffix " a")]
    (match (config.parse-linux
      (byte_buf.str-as-bytes "")
      (byte_buf.str-as-bytes (& source)))
      [(ResolverConfigErr _) (io.panic "256 suffix wire bytes rejected")]
      [(ResolverConfigOk snapshot)
        (test.assert-i64-eq
          (config.suffix-count (& snapshot))
          2
          "suffix wire inclusive")]))
  (let
    [source : String
      "domain old.example\nsearch new.example other.example\nsearch # clear\nrotate\nsortlist 10.0.0.0/8"]
    (match (config.parse-linux
      (byte_buf.str-as-bytes "203.0.113.1 localhost")
      (byte_buf.str-as-bytes (& source)))
      [(ResolverConfigErr _) (io.panic "search clearing")]
      [(ResolverConfigOk snapshot)
        (test.assert-i64-eq
          (config.suffix-count (& snapshot))
          0
          "last empty search")
        (test.assert-i64-eq
          (config.diagnostic-count (& snapshot))
          2
          "unsupported policy")
        (let
          [loopback : config.HostAddresses (config.localhost-addresses)]
          [v6 : ip.IpAddr (config.address-ref (& loopback) 0)]
          [v4 : ip.IpAddr (config.address-ref (& loopback) 1)]
          (test.assert-string-eq
            (& (ip.ip-to-string (& v6)))
            "::1"
            "localhost v6 policy")
          (test.assert-string-eq
            (& (ip.ip-to-string (& v4)))
            "127.0.0.1"
            "localhost v4 policy"))]))
  (let
    [source : byte_buf.ByteBuf (byte_buf.new)]
    [index : i64 4096]
    (while (> index 0)
      (set! index (- index 1))
      (let
        [address : ip.Ipv4Addr
          (ip.ipv4 10 0 (cast (/ index 256) : u8) (cast (% index 256) : u8))]
        (set!
          source
          (byte_buf.append-string source (ip.ipv4-to-string (& address))))
        (set! source (byte_buf.append-string source " shared\n"))))
    (match (config.parse-hosts (byte_buf.as-bytes (& source)))
      [(HostsSnapshotErr _) (io.panic "4096 unique addresses")]
      [(HostsSnapshotOk hosts)
        (let
          [query : String "SHARED."]
          (match (names.parse (& query))
            [(DnsNameErr _) (io.panic "shared query")]
            [(DnsNameOk name)
              (let
                [addresses : config.HostAddresses
                  (config.hosts-lookup (& hosts) (& name))]
                (test.assert-i64-eq
                  (config.address-count (& addresses))
                  4096
                  "preserve every address")
                (set! index 0)
                (while (< index 4096)
                  (let
                    [actual : ip.IpAddr
                      (config.address-ref (& addresses) index)]
                    [expected : ip.IpAddr
                      (V4
                        (ip.ipv4
                          10
                          0
                          (cast (/ index 256) : u8)
                          (cast (% index 256) : u8)))]
                    (test.assert-true
                      (ip.ip-eq? (& actual) (& expected))
                      "ascending network bytes"))
                  (set! index (+ index 1))))]))])))

(define (fake-source [source : config.ConfigSource]) : linux.ConfigBytesResult
  (match source
    [(ConfigHosts)
      (ConfigBytesOk (byte_buf.append-string (byte_buf.new) "::1 fixture"))]
    [(ConfigResolv)
      (ConfigBytesOk
        (byte_buf.append-string
          (byte_buf.new)
          "nameserver ::1\nsearch injected.example"))]
    [(ConfigExplicit) (ConfigBytesErr (linux.unavailable source 22))]))

(define (failed-source [source : config.ConfigSource]) : linux.ConfigBytesResult
  (match source
    [(ConfigHosts) (fake-source source)]
    [_ (ConfigBytesErr (linux.unavailable source 13))]))

(define short-read-position : i64
  0)
(define short-read-close-count : i64
  0)

(define (one-byte-read [handle : io.FileHandle] [requested : i64]) : io.ResultIoRead
  (test.assert-i64-eq handle.id 777 "injected read handle")
  (let
    [bytes : byte_buf.ByteBuf (byte_buf.with-capacity requested)]
    (if (= short-read-position 256)
      (OkIoRead (io.FileRead bytes true))
      (begin
        (set! bytes (byte_buf.push bytes (cast short-read-position : u8)))
        (set! short-read-position (+ short-read-position 1))
        (OkIoRead (io.FileRead bytes false))))))

(define (count-source-close [handle : io.FileHandle]) : io.ResultIoUnit
  (test.assert-i64-eq handle.id 777 "injected close handle")
  (set! short-read-close-count (+ short-read-close-count 1))
  (OkIoUnit))

(define (zero-progress-read [handle : io.FileHandle] [_requested : i64]) : io.ResultIoRead
  (test.assert-i64-eq handle.id 777 "zero-progress handle")
  (OkIoRead (io.FileRead (byte_buf.new) false)))

(define (failed-read [handle : io.FileHandle] [_requested : i64]) : io.ResultIoRead
  (test.assert-i64-eq handle.id 777 "failed-read handle")
  (ErrIoRead (IoSystemCode 13 "injected")))

(define (failed-close [handle : io.FileHandle]) : io.ResultIoUnit
  (let
    [result : io.ResultIoUnit (count-source-close handle)]
    (match result
      [(OkIoUnit) unit]
      [(ErrIoUnit _) unit]))
  (ErrIoUnit (IoSystemCode 5 "injected")))

(define (short-read-checks) : unit
  (set! short-read-position 0)
  (set! short-read-close-count 0)
  (profile.alloc-reset-peak)
  (let
    [before : i64 (profile.alloc-live)]
    [result : linux.ConfigBytesResult
      (linux.read-open-source
        (ConfigHosts)
        (io.FileHandle 777)
        one-byte-read
        count-source-close)]
    [retained : i64 (- (profile.alloc-live) before)]
    [peak : i64 (- (profile.alloc-peak) before)]
    (test.assert-i64-eq
      short-read-close-count
      1
      "short-reading source closes once")
    (match result
      [(ConfigBytesErr _) (io.panic "short-reading source failed")]
      [(ConfigBytesOk bytes)
        (test.assert-i64-eq (byte_buf.len (& bytes)) 256 "all short-read bytes")
        (let
          [index : i64 0]
          (while (< index 256)
            (test.assert-i64-eq
              (cast (byte_buf.ref (& bytes) index) : i64)
              index
              "short-read byte identity")
            (set! index (+ index 1))))])
    (test.assert-i64-eq
      (if (<= retained 2097152)
        0
        retained)
      0
      "bounded retained short-read memory")
    (test.assert-i64-eq
      (if (<= peak 4194304)
        0
        peak)
      0
      "bounded peak short-read memory"))
  (set! short-read-close-count 0)
  (match (linux.read-open-source
    (ConfigHosts)
    (io.FileHandle 777)
    zero-progress-read
    count-source-close)
    [(ConfigBytesOk _) (io.panic "zero-progress read accepted")]
    [(ConfigBytesErr error)
      (test.assert-i64-eq error.host-code 5 "zero-progress failure")])
  (test.assert-i64-eq short-read-close-count 1 "zero progress closes once")
  (set! short-read-close-count 0)
  (match (linux.read-open-source
    (ConfigHosts)
    (io.FileHandle 777)
    failed-read
    failed-close)
    [(ConfigBytesOk _) (io.panic "failed read accepted")]
    [(ConfigBytesErr error)
      (test.assert-i64-eq error.host-code 13 "read error precedes close error")])
  (test.assert-i64-eq short-read-close-count 1 "read failure closes once")
  (set! short-read-position 0)
  (set! short-read-close-count 0)
  (match (linux.read-open-source
    (ConfigHosts)
    (io.FileHandle 777)
    one-byte-read
    failed-close)
    [(ConfigBytesOk _) (io.panic "close failure accepted")]
    [(ConfigBytesErr error)
      (test.assert-i64-eq error.host-code 5 "close failure rejects replacement")])
  (test.assert-i64-eq short-read-close-count 1 "close failure closes once"))

(define (loader-checks) : unit
  (match (linux.load-with-source fake-source)
    [(ResolverConfigErr _) (io.panic "injected loader")]
    [(ResolverConfigOk snapshot)
      (match (linux.load-with-source failed-source)
        [(ResolverConfigOk _) (io.panic "loader failure accepted")]
        [(ResolverConfigErr error)
          (test.assert-i64-eq error.host-code 13 "unreadable injected source")
          (test.assert-i64-eq
            (config.server-count (& snapshot))
            1
            "prior snapshot untouched")])])
  (match (fs.try-create-temp-dir "typelisp-resolver-config")
    [(ErrIoString _) (io.panic "temporary fixture directory")]
    [(OkIoString directory)
      (let
        [path : String (fs.path-join (& directory) "hosts")]
        (io.write-file (& path) (byte_buf.str-as-bytes "::1 fixture\r\n"))
        (match (linux.read-source-path (ConfigHosts) (& path))
          [(ConfigBytesErr _) (io.panic "bounded file read")]
          [(ConfigBytesOk source)
            (match (config.parse-hosts (byte_buf.as-bytes (& source)))
              [(HostsSnapshotErr _) (io.panic "file source parse")]
              [(HostsSnapshotOk hosts)
                (test.assert-i64-eq
                  (config.binding-count (& hosts))
                  1
                  "filesystem snapshot")])])
        (let
          [missing : String (fs.path-join (& directory) "missing")]
          (match (linux.read-source-path (ConfigResolv) (& missing))
            [(ConfigBytesOk _) (io.panic "missing file accepted")]
            [(ConfigBytesErr error)
              (test.assert-i64-eq error.host-code 2 "missing file error")]))
        (let
          [oversized : String (repeat-text "#" 1048577)]
          (io.write-file (& path) (byte_buf.str-as-bytes (& oversized))))
        (match (linux.read-source-path (ConfigHosts) (& path))
          [(ConfigBytesOk _) (io.panic "oversized file read")]
          [(ConfigBytesErr error)
            (test.assert-i64-eq
              (kind-code error.kind)
              1
              "bounded reader overflow")])
        (match (linux.read-source-path (ConfigHosts) (& directory))
          [(ConfigBytesOk _) (io.panic "directory read")]
          [(ConfigBytesErr _) unit]))]))

(define (snapshot-checks) : unit
  (let
    [hosts : String
      "# comment\r\n192.0.2.2 EXAMPLE Alias\r\n::2 example\n::1 ALIAS example\n192.0.2.2 example"]
    [resolv : String
      "nameserver 192.0.2.53\nnameserver ::1\nnameserver 192.0.2.53\nsearch OLD.example\ndomain FINAL.example.\noptions timeout:30 attempts:9 ndots:9\n"]
    (match (config.parse-linux
      (byte_buf.str-as-bytes (& hosts))
      (byte_buf.str-as-bytes (& resolv)))
      [(ResolverConfigErr _) (io.panic "valid snapshot")]
      [(ResolverConfigOk snapshot)
        (test.assert-i64-eq (config.server-count (& snapshot)) 2 "server dedup")
        (test.assert-i64-eq
          (config.suffix-count (& snapshot))
          1
          "last directive")
        (test.assert-string-eq
          (names.text (config.suffix-ref (& snapshot) 0))
          "final.example"
          "suffix canonical")
        (test.assert-i64-eq
          (config.attempt-timeout-ms (& snapshot))
          1000
          "ignored options")
        (test.assert-i64-eq
          (config.diagnostic-count (& snapshot))
          1
          "unsupported diagnostic")
        (let
          [query : String "ExAmPlE."]
          (match (names.parse (& query))
            [(DnsNameErr _) (io.panic "query name")]
            [(DnsNameOk name)
              (let
                [matches : config.HostAddresses
                  (config.hosts-lookup (config.hosts (& snapshot)) (& name))]
                (test.assert-i64-eq
                  (config.address-count (& matches))
                  3
                  "all unique addresses")
                (let
                  [first : ip.IpAddr (config.address-ref (& matches) 0)]
                  (test.assert-string-eq
                    (& (ip.ip-to-string (& first)))
                    "::1"
                    "IPv6 first")))]))])))

(define (run-suite) : i64
  (short-read-checks)
  (name-checks)
  (name-boundary-checks)
  (snapshot-checks)
  (parser-boundary-checks)
  (explicit-checks)
  (exact-limit-checks)
  (loader-checks)
  42)

(define (main) : i64
  (run-suite))

(test
  net-resolver-config-api
  (test.assert-i64-eq (run-suite) 42 "resolver snapshot API"))