(import stdlib.byte_buf)
(import stdlib.net.dns.wire)
(import stdlib.string)
(import stdlib.test)

(define (u16 [out : byte_buf.ByteBuf] [value : i64]) : byte_buf.ByteBuf
  (byte_buf.push
    (byte_buf.push out (cast (shr value 8) : u8))
    (cast (bit-and value 255) : u8)))

(define (u32 [out : byte_buf.ByteBuf] [value : i64]) : byte_buf.ByteBuf
  (u16 (u16 out (shr value 16)) (bit-and value 65535)))

(define (pointer [target : i64]) : byte_buf.ByteBuf
  (u16 (byte_buf.new) (+ 49152 target)))

(define (root) : byte_buf.ByteBuf
  (byte_buf.push (byte_buf.new) 0))

(define (text-label [out : byte_buf.ByteBuf] [text : String]) : byte_buf.ByteBuf
  (byte_buf.append-string
    (byte_buf.push out (cast (string-length text) : u8))
    text))

(define (header [flags : i64] [an : i64] [ns : i64] [ar : i64]) : byte_buf.ByteBuf
  (u16 (u16 (u16 (u16 (u16 (u16 (byte_buf.new) 0x1234) flags) 1) an) ns) ar))

(define (question
  [out : byte_buf.ByteBuf]
  [name : byte_buf.ByteBuf]
  [qtype : i64]) : byte_buf.ByteBuf
  (u16 (u16 (byte_buf.append-bytes out (byte_buf.as-bytes (& name))) qtype) 1))

(define (message [an : i64] [ns : i64] [ar : i64]) : byte_buf.ByteBuf
  (question (header 0x8180 an ns ar) (root) 1))

(define (rr
  [out : byte_buf.ByteBuf]
  [name : byte_buf.ByteBuf]
  [rtype : i64]
  [rclass : i64]
  [ttl : i64]
  [data : byte_buf.ByteBuf]) : byte_buf.ByteBuf
  (let
    [out : byte_buf.ByteBuf
      (byte_buf.append-bytes out (byte_buf.as-bytes (& name)))]
    (byte_buf.append-bytes
      (u16 (u32 (u16 (u16 out rtype) rclass) ttl) (byte_buf.len (& data)))
      (byte_buf.as-bytes (& data)))))

(define (a-data) : byte_buf.ByteBuf
  (u32 (byte_buf.new) 0xc0000201))

(define (assert-bytes
  [actual : (& actual byte_buf.ByteBuf)]
  [expected : (& expected byte_buf.ByteBuf)]) : unit
  (test.assert-i64-eq
    (byte_buf.len actual)
    (byte_buf.len expected)
    "exact wire length")
  (when
    (= (byte_buf.len actual) (byte_buf.len expected))
    (let
      [i : i64 0]
      (while (< i (byte_buf.len actual))
        (test.assert-i64-eq
          (cast (byte_buf.ref actual i) : i64)
          (cast (byte_buf.ref expected i) : i64)
          "exact wire octet")
        (set! i (+ i 1))))))

(define (assert-error [input : (& input bytes)] [limit : bool]) : unit
  (match (wire.decode-response input)
    [(DnsResponseErr error)
      (test.assert-true (>= error.offset 0) "nonnegative error offset")
      (match error.kind
        [(DnsMalformed) (test.assert-false limit "expected malformed")]
        [(DnsLimitExceeded) (test.assert-true limit "expected resource limit")])]
    [_ (test.assert-true false "response must fail atomically")]))

(define (assert-complete [packet : (& packet byte_buf.ByteBuf)] [count : i64]) : unit
  (match (wire.decode-response (byte_buf.as-bytes packet))
    [(DnsComplete msg) (test.assert-i64-eq msg.len count "typed record count")]
    [_ (test.assert-true false "complete response")]))

(define (assert-tc [input : (& input bytes)]) : unit
  (match (wire.decode-response input)
    [(DnsTruncated envelope)
      (test.assert-i64-eq (cast envelope.header.id : i64) 0x1234 "TC id")
      (test.assert-i64-eq envelope.question.name.len 1 "TC complete question")
      (test.assert-i64-eq
        (cast envelope.question.qclass : i64)
        1
        "TC exact class")]
    [_ (test.assert-true false "TC exposes only envelope")]))

(define (repeated-text [n : i64] [value : u8]) : String
  (let
    [out : byte_buf.ByteBuf (byte_buf.with-capacity n)]
    [i : i64 0]
    (while (< i n)
      (set! out (byte_buf.push out value))
      (set! i (+ i 1)))
    (byte_buf.to-string out)))

(define (assert-name [text : (& text str)] [length : i64]) : unit
  (match (wire.parse-name text)
    [(DnsNameOk name)
      (test.assert-i64-eq name.len length "expanded wire length")]
    [_ (test.assert-true false "valid canonical name")]))

(define (assert-name-error [text : (& text str)] [limit : bool]) : unit
  (match (wire.parse-name text)
    [(DnsNameErr error)
      (match error.kind
        [(DnsMalformed) (test.assert-false limit "malformed text")]
        [(DnsLimitExceeded) (test.assert-true limit "text bound")])]
    [_ (test.assert-true false "invalid text accepted")]))

(test
  dns-query-exact-bytes-and-canonical-case
  (let
    [text : String "EXAMPLE.COM."]
    [expected-name : byte_buf.ByteBuf
      (byte_buf.push (text-label (text-label (byte_buf.new) "example") "com") 0)]
    [expected : byte_buf.ByteBuf (question (header 256 0 0 0) expected-name 1)]
    (match (wire.encode-query (& text) 1 0x1234 true false)
      [(DnsQueryOk query) (assert-bytes (& query) (& expected))]
      [_ (test.assert-true false "query accepted")])
    (let
      [text : String "example.com"]
      (match (wire.encode-query (& text) 1 0x1234 true false)
        [(DnsQueryOk query) (assert-bytes (& query) (& expected))]
        [_ (test.assert-true false "lowercase equivalence")]))
    (let
      [text : String "."]
      [expected : byte_buf.ByteBuf
        (rr
          (question (header 0 0 0 1) (root) 28)
          (root)
          41
          1232
          0
          (byte_buf.new))]
      (match (wire.encode-query (& text) 28 0x1234 false true)
        [(DnsQueryOk query) (assert-bytes (& query) (& expected))]
        [_ (test.assert-true false "AAAA EDNS0 query")]))
    (match (wire.encode-query (& text) 5 0 true false)
      [(DnsQueryErr _) unit]
      [_ (test.assert-true false "only A and AAAA queries")])))

(test
  dns-text-name-boundaries
  (assert-name "" 1)
  (assert-name "." 1)
  (assert-name "A." 3)
  (assert-name (repeated-text 63 97) 65)
  (assert-name-error (repeated-text 64 97) true)
  (assert-name-error ".a" false)
  (assert-name-error "a..b" false)
  (assert-name-error "a.." false)
  (assert-name-error "é" false)
  (let
    [label : String (repeated-text 63 97)]
    [last : String (repeated-text 61 98)]
    [max : String
      (string.concat
        (string.concat (string.concat label ".") (string.concat label "."))
        (string.concat (string.concat label ".") last))]
    (assert-name max 255)
    (assert-name (string.concat max ".") 255)
    (assert-name-error (string.concat max "x") true))
  (let
    [text : String "a"]
    [i : i64 1]
    (while (< i 127)
      (set! text (string.concat text ".a"))
      (set! i (+ i 1)))
    (assert-name text 255)
    (assert-name-error (string.concat text ".a") true)))

(test
  dns-typed-sections-and-opaque-skipping
  (let
    [name : byte_buf.ByteBuf
      (byte_buf.push (text-label (text-label (byte_buf.new) "EXAMPLE") "COM") 0)]
    [packet : byte_buf.ByteBuf (question (header 0x8180 3 1 3) name 28)]
    [v6 : byte_buf.ByteBuf
      (u32 (u32 (u32 (u32 (byte_buf.new) 0x20010db8) 0) 0) 1)]
    [soa : byte_buf.ByteBuf (u16 (pointer 12) 49164)]
    [options : byte_buf.ByteBuf (u16 (u16 (u16 (byte_buf.new) 65001) 2) 0xabcd)]
    (set! soa (u32 (u32 (u32 (u32 (u32 soa 0xffffffff) 2) 3) 4) 5))
    (set! packet (rr packet (pointer 12) 1 1 60 (a-data)))
    (set! packet (rr packet (pointer 12) 28 1 120 v6))
    (set! packet (rr packet (pointer 12) 5 1 30 (pointer 12)))
    (set! packet (rr packet (pointer 12) 6 1 90 soa))
    ;; Unknown type and unknown class contain deliberately invalid names.
    (set! packet (rr packet (pointer 12) 65000 1 0 (u16 (byte_buf.new) 0xffff)))
    (set! packet (rr packet (pointer 12) 1 3 0 (root)))
    (set! packet (rr packet (root) 41 1232 0x01008000 options))
    (match (wire.decode-response (byte_buf.as-bytes (& packet)))
      [(DnsComplete msg)
        (test.assert-i64-eq msg.len 5 "only supported records")
        (test.assert-i64-eq
          (cast msg.envelope.question.qtype : i64)
          28
          "exact question")
        (test.assert-i64-eq
          (cast (array-ref msg.envelope.question.name.octets 1) : i64)
          101
          "ASCII lowercase")
        (let
          [record : (& msg wire.DnsRecord) (& (array-ref msg.records 0))]
          (test.assert-i64-eq record.ttl 60 "address TTL")
          (match record.data
            [(DnsA octets)
              (test.assert-i64-eq (cast (array-ref octets 3) : i64) 1 "A bytes")]
            [_ (test.assert-true false "A type")]))
        (match (array-ref msg.records 1).data
          [(DnsAaaa octets)
            (test.assert-i64-eq
              (cast (array-ref octets 15) : i64)
              1
              "AAAA bytes")]
          [_ (test.assert-true false "AAAA type")])
        (match (array-ref msg.records 2).data
          [(DnsCname name)
            (test.assert-true
              (wire.name-eq? (& name) (& msg.envelope.question.name))
              "CNAME canonical target")]
          [_ (test.assert-true false "CNAME type")])
        (test.assert-i64-eq
          (array-ref msg.records 3).section
          1
          "authority section")
        (match (array-ref msg.records 3).data
          [(DnsSoaData soa)
            (test.assert-i64-eq soa.serial 4294967295 "unsigned SOA serial")
            (test.assert-i64-eq soa.minimum 5 "SOA minimum")]
          [_ (test.assert-true false "SOA type")])
        (test.assert-i64-eq
          (array-ref msg.records 4).section
          2
          "additional section")
        (match (array-ref msg.records 4).data
          [(DnsOptData opt)
            (test.assert-i64-eq (cast opt.udp-bytes : i64) 1232 "OPT UDP size")
            (test.assert-i64-eq
              (cast opt.extended-rcode : i64)
              1
              "OPT extended RCODE")
            (test.assert-i64-eq (cast opt.flags : i64) 32768 "OPT flags")]
          [_ (test.assert-true false "OPT type")])]
      [_ (test.assert-true false "all typed records decode")])
    ;; Every proper byte prefix is malformed with TC clear, including a bad
    ;; later section after valid address records: no prefix returns Complete.
    (let
      [i : i64 0]
      (while (< i (byte_buf.len (& packet)))
        (assert-error
          (byte_buf.bytes-slice-view (byte_buf.as-bytes (& packet)) 0 i)
          false)
        (set! i (+ i 1))))))

(test
  dns-truncated-envelope-prefix-matrix
  (let
    [packet : byte_buf.ByteBuf
      (rr (message 1 0 0) (pointer 12) 1 1 60 (a-data))]
    (set! packet (byte_buf.set! packet 2 0x83))
    (let
      [i : i64 0]
      (while (< i 17)
        (assert-error
          (byte_buf.bytes-slice-view (byte_buf.as-bytes (& packet)) 0 i)
          false)
        (set! i (+ i 1)))
      (while (<= i (byte_buf.len (& packet)))
        (assert-tc
          (byte_buf.bytes-slice-view (byte_buf.as-bytes (& packet)) 0 i))
        (set! i (+ i 1))))
    (set! packet (byte_buf.set! packet 6 255))
    (set! packet (byte_buf.set! packet 7 255))
    (assert-tc (byte_buf.as-bytes (& packet)))
    (set! packet (byte_buf.set! packet 4 1))
    (assert-error (byte_buf.as-bytes (& packet)) false))
  (let
    [packet : byte_buf.ByteBuf (question (header 0x8380 0 0 0) (pointer 12) 1)]
    (assert-error (byte_buf.as-bytes (& packet)) false)))

(define (chain-message [links : i64] [repeats : i64]) : byte_buf.ByteBuf
  (let
    [packet : byte_buf.ByteBuf (message (+ links repeats) 0 0)]
    [target : i64 12]
    [i : i64 0]
    ;; Unknown records let us build pointer chains without an address budget.
    (while (< i links)
      (let
        [start : i64 (byte_buf.len (& packet))]
        (set! packet (rr packet (pointer target) 65000 1 0 (byte_buf.new)))
        (set! target start))
      (set! i (+ i 1)))
    (set! i 0)
    (while (< i repeats)
      (set! packet (rr packet (pointer target) 65000 1 0 (byte_buf.new)))
      (set! i (+ i 1)))
    packet))

(test
  dns-compression-boundaries-cycles-and-hops
  (let
    [packet : byte_buf.ByteBuf (chain-message 32 0)]
    (assert-complete (& packet) 0))
  (let
    [packet : byte_buf.ByteBuf (chain-message 33 0)]
    (assert-error (byte_buf.as-bytes (& packet)) true))
  (let
    [packet : byte_buf.ByteBuf (chain-message 31 112)]
    (assert-complete (& packet) 0))
  (let
    [packet : byte_buf.ByteBuf (chain-message 31 113)]
    (assert-error (byte_buf.as-bytes (& packet)) true))
  (let
    [target : i64 0]
    (while (< target 18)
      ;; All targets other than the root at 12 are header/field/interior,
      ;; forward, or self pointers, even if those bytes look like root labels.
      (when
        (!= target 12)
        (let
          [packet : byte_buf.ByteBuf
            (rr (message 1 0 0) (pointer target) 65000 1 0 (byte_buf.new))]
          (assert-error (byte_buf.as-bytes (& packet)) false)))
      (set! target (+ target 1))))
  (let
    [owner : byte_buf.ByteBuf (u16 (text-label (byte_buf.new) "a") 49169)]
    (let
      [packet : byte_buf.ByteBuf
        (rr (message 1 0 0) owner 65000 1 0 (byte_buf.new))]
      (assert-error (byte_buf.as-bytes (& packet)) false)))
  (let
    [tag : i64 64]
    (while (< tag 192)
      (let
        [packet : byte_buf.ByteBuf
          (question
            (header 0x8180 0 0 0)
            (byte_buf.push (byte_buf.new) (cast tag : u8))
            1)]
        (assert-error (byte_buf.as-bytes (& packet)) false))
      (set! tag (+ tag 1))))
  (let
    [name : byte_buf.ByteBuf (text-label (byte_buf.new) "x")]
    ;; A pointer into a label payload must not be mistaken for its zero byte.
    (set! name (byte_buf.set! name 1 0))
    (set! name (byte_buf.push name 0))
    (let
      [packet : byte_buf.ByteBuf
        (rr
          (question (header 0x8180 1 0 0) name 1)
          (pointer 13)
          65000
          1
          0
          (byte_buf.new))]
      (assert-error (byte_buf.as-bytes (& packet)) false))))

(test
  dns-record-and-message-bounds
  (let
    [count : i64 64]
    (while (<= count 65)
      (let
        [packet : byte_buf.ByteBuf (message count 0 0)]
        [i : i64 0]
        (while (< i count)
          (set! packet (rr packet (pointer 12) 1 1 0 (a-data)))
          (set! i (+ i 1)))
        (if (= count 64)
          (assert-complete (& packet) 64)
          (assert-error (byte_buf.as-bytes (& packet)) true)))
      (set! count (+ count 1))))
  (let
    [packet : byte_buf.ByteBuf (chain-message 0 255)]
    (assert-complete (& packet) 0))
  (let
    [packet : byte_buf.ByteBuf (chain-message 0 256)]
    (assert-error (byte_buf.as-bytes (& packet)) true))
  (let
    [packet : byte_buf.ByteBuf (message 257 0 0)]
    (assert-error (byte_buf.as-bytes (& packet)) true))
  (let
    [data : byte_buf.ByteBuf (byte_buf.from-array (__tl_make-array u8 65507))]
    [packet : byte_buf.ByteBuf (rr (message 1 0 0) (root) 65000 1 0 data)]
    (test.assert-i64-eq (byte_buf.len (& packet)) 65535 "max input fixture")
    (assert-complete (& packet) 0)
    (set! packet (byte_buf.push packet 0))
    (assert-error (byte_buf.as-bytes (& packet)) true))
  (let
    [n : i64 0]
    (while (< n 18)
      (when
        (or (!= n 4) (!= n 16))
        (let
          [data : byte_buf.ByteBuf (byte_buf.from-array (__tl_make-array u8 n))]
          (when
            (!= n 4)
            (let
              [packet : byte_buf.ByteBuf
                (rr
                  (message 1 0 0)
                  (pointer 12)
                  1
                  1
                  0
                  (byte_buf.from-bytes (byte_buf.as-bytes (& data))))]
              (assert-error (byte_buf.as-bytes (& packet)) false)))
          (when
            (!= n 16)
            (let
              [packet : byte_buf.ByteBuf
                (rr (message 1 0 0) (pointer 12) 28 1 0 data)]
              (assert-error (byte_buf.as-bytes (& packet)) false)))))
      (set! n (+ n 1))))
  (let
    [packet : byte_buf.ByteBuf
      (rr (message 1 0 0) (pointer 12) 5 1 0 (u16 (root) 0))]
    (assert-error (byte_buf.as-bytes (& packet)) false))
  (let
    [packet : byte_buf.ByteBuf
      (rr (message 0 0 1) (root) 41 1232 0 (u16 (u16 (byte_buf.new) 1) 1))]
    (assert-error (byte_buf.as-bytes (& packet)) false))
  (let
    [packet : byte_buf.ByteBuf
      (rr
        (rr (message 0 0 2) (root) 41 1232 0 (byte_buf.new))
        (root)
        41
        1232
        0
        (byte_buf.new))]
    (assert-error (byte_buf.as-bytes (& packet)) false)))

(test
  dns-wire-name-expansion-and-field-extents
  (let
    [tail : i64 61]
    (while (<= tail 62)
      (let
        [label : String (repeated-text 63 97)]
        [name : byte_buf.ByteBuf
          (byte_buf.push
            (text-label
              (text-label
                (text-label
                  (text-label (byte_buf.new) (clone label))
                  (clone label))
                label)
              (repeated-text tail 98))
            0)]
        [packet : byte_buf.ByteBuf (question (header 0x8180 0 0 0) name 1)]
        (if (= tail 61)
          (assert-complete (& packet) 0)
          (assert-error (byte_buf.as-bytes (& packet)) true)))
      (set! tail (+ tail 1))))
  (let
    [packet : byte_buf.ByteBuf (chain-message 31 112)]
    ;; 496 + 112*32 + 16 = exactly 4096 compression hops.
    (set! packet (rr packet (pointer 185) 65000 1 0 (byte_buf.new)))
    (set! packet (byte_buf.set! packet 7 144))
    (assert-complete (& packet) 0)
    (set! packet (rr packet (pointer 12) 65000 1 0 (byte_buf.new)))
    (set! packet (byte_buf.set! packet 7 145))
    (assert-error (byte_buf.as-bytes (& packet)) true))
  ;; A CNAME pointer may expand beyond RDLENGTH, but its encoded pointer may
  ;; not borrow a missing second byte from the following RR.
  (let
    [packet : byte_buf.ByteBuf
      (rr (message 1 0 0) (pointer 12) 5 1 0 (pointer 12))]
    (assert-complete (& packet) 1)
    (set! packet (byte_buf.set! packet 28 1))
    (assert-error (byte_buf.as-bytes (& packet)) false))
  (let
    [packet : byte_buf.ByteBuf
      (rr (message 1 0 0) (pointer 12) 6 1 0 (u32 (root) 1))]
    (assert-error (byte_buf.as-bytes (& packet)) false))
  (let
    [packet : byte_buf.ByteBuf
      (rr (message 1 0 0) (root) 41 1232 0 (byte_buf.new))]
    (assert-error (byte_buf.as-bytes (& packet)) false))
  (let
    [packet : byte_buf.ByteBuf
      (question
        (header 0x8180 0 0 0)
        (byte_buf.push (text-label (byte_buf.new) "é") 0)
        1)]
    (assert-error (byte_buf.as-bytes (& packet)) false)))

(define (mix [hash : i64] [value : i64]) : i64
  (bit-and (+ (* hash 33) (bit-and value 0x7fffffff)) 0x7fffffff))

(define (name-hash [hash : i64] [name : (& name wire.DnsName)]) : i64
  (let
    [hash : i64 (mix hash name.len)]
    [i : i64 0]
    (while (< i name.len)
      (set! hash (mix hash (cast (array-ref name.octets i) : i64)))
      (set! i (+ i 1)))
    hash))

(define (envelope-hash [envelope : (& envelope wire.DnsEnvelope)]) : i64
  (name-hash
    (mix
      (mix
        (mix
          (mix
            (mix
              (mix
                (mix
                  (mix 1 (cast envelope.header.id : i64))
                  (cast envelope.header.flags : i64))
                envelope.header.questions)
              envelope.header.answers)
            envelope.header.authorities)
          envelope.header.additionals)
        (cast envelope.question.qtype : i64))
      (cast envelope.question.qclass : i64))
    (& envelope.question.name)))

(define (response-hash [input : (& input bytes)]) : i64
  (match (wire.decode-response input)
    [(DnsResponseErr error)
      (-
        0
        (+
          1
          (+
            (* error.offset 2)
            (match error.kind
              [(DnsMalformed) 0]
              [(DnsLimitExceeded) 1]))))]
    [(DnsTruncated envelope) (mix (envelope-hash (& envelope)) 123)]
    [(DnsComplete msg)
      (let
        [hash : i64 (mix (envelope-hash (& msg.envelope)) msg.len)]
        [i : i64 0]
        (while (< i msg.len)
          (let
            [record : (& msg wire.DnsRecord) (& (array-ref msg.records i))]
            (set!
              hash
              (name-hash
                (mix (mix hash record.ttl) record.section)
                (& record.owner)))
            (match record.data
              [(DnsA octets)
                (set! hash (mix hash 1))
                (let
                  [j : i64 0]
                  (while (< j 4)
                    (set! hash (mix hash (cast (array-ref octets j) : i64)))
                    (set! j (+ j 1))))]
              [(DnsAaaa octets)
                (set! hash (mix hash 28))
                (let
                  [j : i64 0]
                  (while (< j 16)
                    (set! hash (mix hash (cast (array-ref octets j) : i64)))
                    (set! j (+ j 1))))]
              [(DnsCname name) (set! hash (name-hash (mix hash 5) (& name)))]
              [(DnsSoaData soa)
                (set!
                  hash
                  (name-hash
                    (name-hash (mix hash 6) (& soa.primary))
                    (& soa.mailbox)))
                (set!
                  hash
                  (mix
                    (mix
                      (mix (mix (mix hash soa.serial) soa.refresh) soa.retry)
                      soa.expire)
                    soa.minimum))]
              [(DnsOptData opt)
                (set!
                  hash
                  (mix
                    (mix
                      (mix
                        (mix (mix hash 41) (cast opt.udp-bytes : i64))
                        (cast opt.extended-rcode : i64))
                      (cast opt.version : i64))
                    (cast opt.flags : i64)))]))
          (set! i (+ i 1)))
        hash)]))

(test
  dns-fixed-seed-bounded-mutation-corpus
  (let
    [base : byte_buf.ByteBuf
      (rr
        (rr
          (rr (message 2 0 1) (pointer 12) 5 1 30 (pointer 12))
          (pointer 12)
          1
          1
          60
          (a-data))
        (root)
        41
        1232
        0
        (byte_buf.new))]
    [seed : i64 7472]
    [case-index : i64 0]
    (while (< case-index 512)
      (with-arena
        mutation
        (let
          [mutated : byte_buf.ByteBuf
            (byte_buf.from-bytes (byte_buf.as-bytes (& base)))]
          [changes : i64 (+ 1 (% case-index 4))]
          [j : i64 0]
          (while (< j changes)
            (set! seed (bit-and (+ (* seed 1103515245) 12345) 0x7fffffff))
            (let
              [offset : i64 (% seed (byte_buf.len (& mutated)))]
              (set! seed (bit-and (+ (* seed 1103515245) 12345) 0x7fffffff))
              (byte_buf.bytes-set!
                (byte_buf.as-mut-bytes (&mut mutated))
                offset
                (cast (bit-and (shr seed 8) 255) : u8)))
            (set! j (+ j 1)))
          (let
            [n : i64
              (if (= (% case-index 3) 0)
                (% seed (+ (byte_buf.len (& mutated)) 1))
                (byte_buf.len (& mutated)))]
            (let
              [view : (& mutated bytes)
                (byte_buf.bytes-slice-view (byte_buf.as-bytes (& mutated)) 0 n)]
              [first : i64 (response-hash view)]
              [second : i64 (response-hash view)]
              (test.assert-i64-eq
                first
                second
                "deterministic full canonical result"))
            ;; Every mutated packet with the unchanged valid root question
            ;; and TC set must return its envelope, whatever the RR suffix.
            (when
              (>= n 17)
              (byte_buf.bytes-set!
                (byte_buf.as-mut-bytes (&mut mutated))
                0
                0x12)
              (byte_buf.bytes-set!
                (byte_buf.as-mut-bytes (&mut mutated))
                1
                0x34)
              (byte_buf.bytes-set!
                (byte_buf.as-mut-bytes (&mut mutated))
                2
                0x83)
              (byte_buf.bytes-set! (byte_buf.as-mut-bytes (&mut mutated)) 4 0)
              (byte_buf.bytes-set! (byte_buf.as-mut-bytes (&mut mutated)) 5 1)
              (byte_buf.bytes-set! (byte_buf.as-mut-bytes (&mut mutated)) 12 0)
              (byte_buf.bytes-set! (byte_buf.as-mut-bytes (&mut mutated)) 13 0)
              (byte_buf.bytes-set! (byte_buf.as-mut-bytes (&mut mutated)) 14 1)
              (byte_buf.bytes-set! (byte_buf.as-mut-bytes (&mut mutated)) 15 0)
              (byte_buf.bytes-set! (byte_buf.as-mut-bytes (&mut mutated)) 16 1)
              (assert-tc
                (byte_buf.bytes-slice-view (byte_buf.as-bytes (& mutated)) 0 n))))))
      (set! case-index (+ case-index 1)))))