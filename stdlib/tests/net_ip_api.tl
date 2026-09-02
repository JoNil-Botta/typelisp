(import stdlib.byte_buf)
(import stdlib.net.ip as net_ip)
(import stdlib.profile)
(import stdlib.test)

(define (fail [message : String]) : unit
  (test.assert-true false message))

(define (ipv4-with-nul) : String
  (let
    [bytes : (__tl_dyn-array u8) (__tl_make-array u8 8)]
    (begin
      (set! (array-ref bytes 0) (cast '1' : u8))
      (set! (array-ref bytes 1) (cast '.' : u8))
      (set! (array-ref bytes 2) (cast '2' : u8))
      (set! (array-ref bytes 3) (cast '.' : u8))
      (set! (array-ref bytes 4) (cast 0 : u8))
      (set! (array-ref bytes 5) (cast '.' : u8))
      (set! (array-ref bytes 6) (cast '4' : u8))
      (set! (array-ref bytes 7) (cast '2' : u8))
      (unsafe
        (string-from-bytes (ptr-cast (__tl_array-data bytes) : (Ptr u8)) 8)))))

(define (error-kind-code [kind : net_ip.IpAddrErrorKind]) : i64
  (match kind
    [(net_ip.IpEmpty) 0]
    [(net_ip.IpInputTooLong) 1]
    [(net_ip.IpInvalidCharacter) 2]
    [(net_ip.IpInvalidSeparator) 3]
    [(net_ip.IpTooFewComponents) 4]
    [(net_ip.IpTooManyComponents) 5]
    [(net_ip.IpLeadingZero) 6]
    [(net_ip.IpComponentOverflow) 7]
    [(net_ip.IpMultipleCompression) 8]
    [(net_ip.IpCompressionWithoutZero) 9]
    [(net_ip.IpEmbeddedIpv4NotFinal) 10]
    [(net_ip.IpInvalidByteLength) 11]))

(define (assert-ipv4-text [source : String] [canonical : String]) : unit
  (match (net_ip.parse-ipv4 (& source))
    [(net_ip.Ipv4Err _) (fail "expected valid IPv4 text")]
    [(net_ip.Ipv4Ok address)
      (let
        [actual : String (net_ip.ipv4-to-string (& address))]
        (test.assert-string-eq (& actual) (& canonical) "IPv4 canonical text"))]))

(define (assert-ipv6-text [source : String] [canonical : String]) : unit
  (match (net_ip.parse-ipv6 (& source))
    [(net_ip.Ipv6Err _) (fail "expected valid IPv6 text")]
    [(net_ip.Ipv6Ok address)
      (let
        [actual : String (net_ip.ipv6-to-string (& address))]
        (begin
          (test.assert-string-eq (& actual) (& canonical) "IPv6 canonical text")
          (match (net_ip.parse-ipv6 (& actual))
            [(net_ip.Ipv6Err _) (fail "canonical IPv6 output did not parse")]
            [(net_ip.Ipv6Ok reparsed)
              (test.assert-true
                (net_ip.ipv6-eq? (& address) (& reparsed))
                "IPv6 format/parse round trip")])))]))

(define (assert-ipv4-error [text : String] [kind-code : i64] [offset : i64]) : unit
  (match (net_ip.parse-ipv4 (& text))
    [(net_ip.Ipv4Ok _) (fail text)]
    [(net_ip.Ipv4Err error)
      (begin
        (test.assert-i64-eq
          (error-kind-code error.kind)
          kind-code
          "IPv4 error kind")
        (test.assert-i64-eq error.offset offset "IPv4 error offset"))]))

(define (assert-ipv6-error [text : String] [kind-code : i64] [offset : i64]) : unit
  (match (net_ip.parse-ipv6 (& text))
    [(net_ip.Ipv6Ok _) (fail text)]
    [(net_ip.Ipv6Err error)
      (begin
        (test.assert-i64-eq
          (error-kind-code error.kind)
          kind-code
          "IPv6 error kind")
        (test.assert-i64-eq error.offset offset "IPv6 error offset"))]))

(define (assert-constructors-and-identity) : unit
  (let
    [v4 : net_ip.Ipv4Addr (net_ip.ipv4 192 0 2 128)]
    [v4-copy : net_ip.Ipv4Addr (net_ip.ipv4 192 0 2 128)]
    [v4-next : net_ip.Ipv4Addr (net_ip.ipv4 192 0 2 129)]
    [mapped : net_ip.Ipv6Addr (net_ip.ipv6 0 0 0 0 0 0xffff 0xc000 0x0280)]
    [mapped-copy : net_ip.Ipv6Addr (net_ip.ipv6 0 0 0 0 0 0xffff 0xc000 0x0280)]
    [as-v4 : net_ip.IpAddr (net_ip.V4 v4)]
    [as-v6 : net_ip.IpAddr (net_ip.V6 mapped)]
    [as-v6-copy : net_ip.IpAddr (net_ip.V6 mapped-copy)]
    (begin
      (test.assert-i64-eq
        (cast (net_ip.ipv4-octet (& v4) 3) : i64)
        128
        "IPv4 constructor octet")
      (test.assert-i64-eq
        (cast (net_ip.ipv6-segment (& mapped) 5) : i64)
        65535
        "IPv6 constructor segment")
      (test.assert-true (net_ip.ipv4-eq? (& v4) (& v4-copy)) "IPv4 equality")
      (test.assert-i64-eq
        (net_ip.ipv4-compare (& v4) (& v4-copy))
        0
        "IPv4 equal ordering")
      (test.assert-i64-eq
        (net_ip.ipv4-compare (& v4) (& v4-next))
        -1
        "IPv4 lexical ordering")
      (test.assert-i64-eq
        (net_ip.ipv4-hash (& v4))
        (net_ip.ipv4-hash (& v4-copy))
        "equal IPv4 hash")
      (test.assert-false
        (net_ip.ip-eq? (& as-v4) (& as-v6))
        "IPv4 remains distinct from mapped IPv6")
      (test.assert-true
        (net_ip.ip-eq? (& as-v6) (& as-v6-copy))
        "family-tagged IPv6 equality")
      (test.assert-i64-eq
        (net_ip.ip-hash (& as-v6))
        (net_ip.ip-hash (& as-v6-copy))
        "family-tagged IPv6 hash")
      (test.assert-i64-eq
        (net_ip.ip-compare (& as-v4) (& as-v6))
        -1
        "IP family ordering")
      (let
        [actual : String (net_ip.ip-to-string (& as-v6))]
        [expected : String "::ffff:c000:280"]
        (test.assert-string-eq
          (& actual)
          (& expected)
          "mapped IPv6 pure hexadecimal policy"))
      (let
        [actual : String (net_ip.ip-to-string (& as-v4))]
        [expected : String "192.0.2.128"]
        (test.assert-string-eq
          (& actual)
          (& expected)
          "family-tagged IPv4 formatting")))))

(define (assert-byte-constructors) : unit
  (let
    [four : String "ABCD"]
    [sixteen : String "abcdefghijklmnop"]
    [three : String "ABC"]
    [fifteen : String "abcdefghijklmno"]
    (begin
      (match (net_ip.ipv4-from-bytes (byte_buf.str-as-bytes (& four)))
        [(net_ip.Ipv4Err _) (fail "four-byte IPv4 rejected")]
        [(net_ip.Ipv4Ok address)
          (begin
            (test.assert-i64-eq
              (cast (net_ip.ipv4-octet (& address) 0) : i64)
              65
              "IPv4 byte order first")
            (test.assert-i64-eq
              (cast (net_ip.ipv4-octet (& address) 3) : i64)
              68
              "IPv4 byte order last"))])
      (match (net_ip.ipv6-from-bytes (byte_buf.str-as-bytes (& sixteen)))
        [(net_ip.Ipv6Err _) (fail "sixteen-byte IPv6 rejected")]
        [(net_ip.Ipv6Ok address)
          (test.assert-i64-eq
            (cast (net_ip.ipv6-segment (& address) 0) : i64)
            0x6162
            "IPv6 byte order")])
      (match (net_ip.ipv4-from-bytes (byte_buf.str-as-bytes (& three)))
        [(net_ip.Ipv4Ok _) (fail "short IPv4 bytes accepted")]
        [(net_ip.Ipv4Err error)
          (begin
            (test.assert-i64-eq
              (error-kind-code error.kind)
              11
              "IPv4 byte length kind")
            (test.assert-i64-eq error.offset 3 "IPv4 byte length value"))])
      (match (net_ip.ipv6-from-bytes (byte_buf.str-as-bytes (& fifteen)))
        [(net_ip.Ipv6Ok _) (fail "short IPv6 bytes accepted")]
        [(net_ip.Ipv6Err error)
          (test.assert-i64-eq error.offset 15 "IPv6 byte length value")])
      (match (net_ip.ip-from-bytes (byte_buf.str-as-bytes (& four)))
        [(net_ip.IpErr _) (fail "family-selected IPv4 bytes rejected")]
        [(net_ip.IpOk address)
          (match address
            [(net_ip.V4 _) unit]
            [(net_ip.V6 _) (fail "four bytes selected IPv6")])])
      (match (net_ip.ip-from-bytes (byte_buf.str-as-bytes (& sixteen)))
        [(net_ip.IpErr _) (fail "family-selected IPv6 bytes rejected")]
        [(net_ip.IpOk address)
          (match address
            [(net_ip.V4 _) (fail "sixteen bytes selected IPv4")]
            [(net_ip.V6 _) unit])]))))

(define (assert-positive-text) : unit
  (begin
    (assert-ipv4-text "0.0.0.0" "0.0.0.0")
    (assert-ipv4-text "255.255.255.255" "255.255.255.255")
    (assert-ipv4-text "192.0.2.128" "192.0.2.128")
    (assert-ipv6-text "::" "::")
    (assert-ipv6-text "::1" "::1")
    (assert-ipv6-text "2001:db8::" "2001:db8::")
    (assert-ipv6-text "0:0:0:0:0:0:0:1" "::1")
    (assert-ipv6-text
      "2001:0DB8:0000:0000:0000:FF00:0042:8329"
      "2001:db8::ff00:42:8329")
    (assert-ipv6-text "2001:db8:0:1:1:1:1:1" "2001:db8:0:1:1:1:1:1")
    (assert-ipv6-text "2001:0:0:1:0:0:1:1" "2001::1:0:0:1:1")
    (assert-ipv6-text "::ffff:192.0.2.128" "::ffff:c000:280")
    (assert-ipv6-text "0:0:0:0:0:ffff:192.0.2.128" "::ffff:c000:280")
    (assert-ipv6-text
      "ffff:ffff:ffff:ffff:ffff:ffff:255.255.255.255"
      "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff")
    (let
      [v4-text : String "203.0.113.9"]
      [v6-text : String "2001:db8::9"]
      (begin
        (match (net_ip.parse-ip (& v4-text))
          [(net_ip.IpErr _) (fail "generic IPv4 parse failed")]
          [(net_ip.IpOk address)
            (match address
              [(net_ip.V4 _) unit]
              [(net_ip.V6 _) (fail "generic IPv4 family")])])
        (match (net_ip.parse-ip (& v6-text))
          [(net_ip.IpErr _) (fail "generic IPv6 parse failed")]
          [(net_ip.IpOk address)
            (match address
              [(net_ip.V4 _) (fail "generic IPv6 family")]
              [(net_ip.V6 _) unit])])))))

(define (assert-negative-text) : unit
  (begin
    (assert-ipv4-error "" 0 0)
    (assert-ipv4-error "01.2.3.4" 6 1)
    (assert-ipv4-error "1.2.3.04" 6 7)
    (assert-ipv4-error "256.2.3.4" 7 2)
    (assert-ipv4-error "1.2.3" 4 5)
    (assert-ipv4-error "1.2.3.4.5" 5 7)
    (assert-ipv4-error "1.2.3.4 " 2 7)
    (assert-ipv4-error "+1.2.3.4" 2 0)
    (assert-ipv4-error "1..3.4" 2 2)
    (assert-ipv4-error (ipv4-with-nul) 2 4)
    (assert-ipv4-error "111.111.111.1111" 1 15)
    (assert-ipv6-error "" 0 0)
    (assert-ipv6-error "1::2::3" 8 4)
    (assert-ipv6-error ":::1" 3 2)
    (assert-ipv6-error "1:2:3:4:5:6:7" 4 13)
    (assert-ipv6-error "1:2:3:4:5:6:7:8:9" 5 16)
    (assert-ipv6-error "1:2:3:4:5:6:7:8::" 9 15)
    (assert-ipv6-error "[::1]" 2 0)
    (assert-ipv6-error "fe80::1%lo" 2 7)
    (assert-ipv6-error "2001:db8::1 " 2 11)
    (assert-ipv6-error "12345::1" 7 4)
    (assert-ipv6-error "1.2.3.4::" 10 0)
    (assert-ipv6-error "::ffff:192.0.2.1:1" 10 16)
    (assert-ipv6-error "::ffff:192.168.001.1" 6 16)
    (assert-ipv6-error "0000000000000000000000000000000000000000000000" 1 45)))

(define (assert-exhaustive-ipv4-suffix-roundtrip) : unit
  (let
    [suffix : i64 0]
    (while (< suffix 65536)
      (let
        [address : net_ip.Ipv4Addr
          (net_ip.ipv4
            192
            0
            (cast (/ suffix 256) : u8)
            (cast (% suffix 256) : u8))]
        [text : String (net_ip.ipv4-to-string (& address))]
        (begin
          (match (net_ip.parse-ipv4 (& text))
            [(net_ip.Ipv4Err _) (fail "exhaustive IPv4 suffix parse")]
            [(net_ip.Ipv4Ok reparsed)
              (test.assert-true
                (net_ip.ipv4-eq? (& address) (& reparsed))
                "exhaustive IPv4 suffix round trip")])
          (set! suffix (+ suffix 1)))))))

(define (assert-generated-ipv6-roundtrip) : unit
  (let
    [seed : i64 0]
    (while (< seed 4096)
      (let
        [address : net_ip.Ipv6Addr
          (net_ip.ipv6
            (cast seed : u16)
            0
            0
            (cast (bit-and (* seed 17) 65535) : u16)
            (cast (bit-and (* seed 257) 65535) : u16)
            0
            (cast (bit-and (* seed 4093) 65535) : u16)
            (cast (bit-and (+ seed 1) 65535) : u16))]
        [text : String (net_ip.ipv6-to-string (& address))]
        (begin
          (match (net_ip.parse-ipv6 (& text))
            [(net_ip.Ipv6Err _) (fail "generated IPv6 parse")]
            [(net_ip.Ipv6Ok reparsed)
              (test.assert-true
                (net_ip.ipv6-eq? (& address) (& reparsed))
                "generated IPv6 round trip")])
          (set! seed (+ seed 1)))))))

(define (expected-string-allocation [length : i64]) : i64
  (+ 16 (* 8 (/ (+ length 7) 8))))

(define (assert-allocation-contract) : unit
  (let
    [v4 : net_ip.Ipv4Addr (net_ip.ipv4 255 255 255 255)]
    [v6 : net_ip.Ipv6Addr (net_ip.ipv6 0 0 0 0 0 0 0 1)]
    [before-v4 : i64 (profile.alloc-total)]
    [v4-text : String (net_ip.ipv4-to-string (& v4))]
    [v4-bytes : i64 (- (profile.alloc-total) before-v4)]
    [before-v6 : i64 (profile.alloc-total)]
    [v6-text : String (net_ip.ipv6-to-string (& v6))]
    [v6-bytes : i64 (- (profile.alloc-total) before-v6)]
    [source : String "2001:db8::1"]
    [before-parse : i64 (profile.alloc-total)]
    [parsed : net_ip.Ipv6AddrResult (net_ip.parse-ipv6 (& source))]
    [parse-bytes : i64 (- (profile.alloc-total) before-parse)]
    (begin
      (test.assert-i64-eq
        v4-bytes
        (expected-string-allocation 15)
        "IPv4 formatter allocates only exact returned String")
      (test.assert-i64-eq
        v6-bytes
        (expected-string-allocation 3)
        "IPv6 formatter allocates only exact returned String")
      (test.assert-i64-eq parse-bytes 0 "IPv6 parser allocation free")
      (match parsed
        [(net_ip.Ipv6Err _) (fail "allocation probe IPv6 rejected")]
        [(net_ip.Ipv6Ok _) unit])
      (test.assert-i64-eq
        (string-length (& v4-text))
        15
        "IPv4 allocation probe result live")
      (test.assert-i64-eq
        (string-length (& v6-text))
        3
        "IPv6 allocation probe result live"))))

(define (main) : i64
  (begin
    (assert-positive-text)
    (assert-constructors-and-identity)
    (assert-byte-constructors)
    (assert-negative-text)
    (assert-exhaustive-ipv4-suffix-roundtrip)
    (assert-generated-ipv6-roundtrip)
    (assert-allocation-contract)
    42))