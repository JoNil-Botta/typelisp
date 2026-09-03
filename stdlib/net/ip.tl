;# Canonical Internet Protocol address values and strict text codecs.
;#
;# IPv4 and IPv6 values store exactly 4 or 16 bytes in network byte order.
;# Parsers borrow their input, allocate nothing, and report the first offending
;# byte. Formatters use stack-owned fixed buffers and allocate only the returned
;# bounded `String`. This module performs no name lookup, socket operation, or
;# other I/O.
;#
;# IPv4 text follows the RFC 3986 dec-octet grammar, including rejection of
;# leading zeros in multi-digit components. IPv6 parsing accepts the RFC 4291
;# hexadecimal, compressed, and final embedded-IPv4 forms. IPv6 formatting
;# follows RFC 5952: lowercase hexadecimal, no leading zeroes, and compression
;# of the first longest run of at least two zero segments. IPv4-embedded values
;# are deliberately formatted as pure hexadecimal, so every 16-byte value has
;# one representation-independent canonical spelling.
;#
;# Usage: `(import stdlib.net.ip)`.
(import stdlib.byte_buf)
(import stdlib.hash)
(import stdlib.string)

;: An IPv4 address represented by exactly four network-order octets.
(defstruct Ipv4Addr
  (octets (Array u8 4)))

;: An IPv6 address represented by exactly sixteen network-order octets.
(defstruct Ipv6Addr
  (octets (Array u8 16)))

;: An IP address whose family remains part of its identity.
(defenum IpAddr
  (V4 Ipv4Addr)
  (V6 Ipv6Addr))

;: Stable categories for text and byte-construction failures.
(defenum IpAddrErrorKind
  (IpEmpty)
  (IpInputTooLong)
  (IpInvalidCharacter)
  (IpInvalidSeparator)
  (IpTooFewComponents)
  (IpTooManyComponents)
  (IpLeadingZero)
  (IpComponentOverflow)
  (IpMultipleCompression)
  (IpCompressionWithoutZero)
  (IpEmbeddedIpv4NotFinal)
  (IpInvalidByteLength))

;: A recoverable failure with the first offending byte offset.
(defstruct IpAddrError
  (kind IpAddrErrorKind)
  (offset i64))

;: Result of constructing or parsing an IPv4 address.
(defenum Ipv4AddrResult
  (Ipv4Ok Ipv4Addr)
  (Ipv4Err IpAddrError))

;: Result of constructing or parsing an IPv6 address.
(defenum Ipv6AddrResult
  (Ipv6Ok Ipv6Addr)
  (Ipv6Err IpAddrError))

;: Result of constructing or parsing an address of either family.
(defenum IpAddrResult
  (IpOk IpAddr)
  (IpErr IpAddrError))

;: Internal parsed IPv6 colon-delimited part.
(defstruct Ipv6Part
  (segments (Array u16 8))
  (count i64))

;: Internal result for one side of an IPv6 compression marker.
(defenum Ipv6PartResult
  (Ipv6PartOk Ipv6Part)
  (Ipv6PartErr IpAddrError))

;: Maximum accepted IPv4 text length.
(define (ipv4-max-text-bytes) : i64
  15)

;: Maximum accepted IPv6 text length, including an embedded dotted suffix.
(define (ipv6-max-text-bytes) : i64
  45)

;: Construct an IPv4 address from four octets.
(define (ipv4 [a : u8] [b : u8] [c : u8] [d : u8]) : Ipv4Addr
  (Ipv4Addr (array a b c d)))

;: Return the high network-order byte of a 16-bit segment.
(define (segment-high-byte [segment : u16]) : u8
  (cast (shr (cast segment : i64) 8) : u8))

;: Return the low network-order byte of a 16-bit segment.
(define (segment-low-byte [segment : u16]) : u8
  (cast (bit-and (cast segment : i64) 255) : u8))

;: Construct an IPv6 address from eight host-order 16-bit segments.
(define (ipv6
  [a : u16]
  [b : u16]
  [c : u16]
  [d : u16]
  [e : u16]
  [f : u16]
  [g : u16]
  [h : u16]) : Ipv6Addr
  (Ipv6Addr
    (array
      (segment-high-byte a)
      (segment-low-byte a)
      (segment-high-byte b)
      (segment-low-byte b)
      (segment-high-byte c)
      (segment-low-byte c)
      (segment-high-byte d)
      (segment-low-byte d)
      (segment-high-byte e)
      (segment-low-byte e)
      (segment-high-byte f)
      (segment-low-byte f)
      (segment-high-byte g)
      (segment-low-byte g)
      (segment-high-byte h)
      (segment-low-byte h))))

;: Construct an IPv6 address from a fixed array of eight host-order segments.
(define (ipv6-from-segments [segments : (Array u16 8)]) : Ipv6Addr
  (ipv6
    (array-ref segments 0)
    (array-ref segments 1)
    (array-ref segments 2)
    (array-ref segments 3)
    (array-ref segments 4)
    (array-ref segments 5)
    (array-ref segments 6)
    (array-ref segments 7)))

;: Return the first missing or extra byte offset for an exact-length input.
(define (invalid-byte-length-offset [actual : i64] [expected : i64]) : i64
  (if (< actual expected)
    actual
    expected))

;: Copy exactly four borrowed bytes into an IPv4 address.
(define (ipv4-from-bytes [input : (& input bytes)]) : Ipv4AddrResult
  (let
    [n : i64 (byte_buf.bytes-length input)]
    (if (!= n 4)
      (Ipv4Err
        (IpAddrError (IpInvalidByteLength) (invalid-byte-length-offset n 4)))
      (Ipv4Ok
        (ipv4
          (byte_buf.bytes-ref input 0)
          (byte_buf.bytes-ref input 1)
          (byte_buf.bytes-ref input 2)
          (byte_buf.bytes-ref input 3))))))

;: Copy exactly sixteen borrowed bytes into an IPv6 address.
(define (ipv6-from-bytes [input : (& input bytes)]) : Ipv6AddrResult
  (let
    [n : i64 (byte_buf.bytes-length input)]
    (if (!= n 16)
      (Ipv6Err
        (IpAddrError (IpInvalidByteLength) (invalid-byte-length-offset n 16)))
      (let
        [out : (Array u8 16) (init)]
        [index : i64 0]
        (begin
          (while (< index 16)
            (begin
              (set! (array-ref out index) (byte_buf.bytes-ref input index))
              (set! index (+ index 1))))
          (Ipv6Ok (Ipv6Addr out)))))))

;: Copy a borrowed four- or sixteen-byte network-order address.
(define (ip-from-bytes [input : (& input bytes)]) : IpAddrResult
  (let
    [n : i64 (byte_buf.bytes-length input)]
    (cond
      [(= n 4)
        (match (ipv4-from-bytes input)
          [(Ipv4Ok address) (IpOk (V4 address))]
          [(Ipv4Err error) (IpErr error)])]
      [(= n 16)
        (match (ipv6-from-bytes input)
          [(Ipv6Ok address) (IpOk (V6 address))]
          [(Ipv6Err error) (IpErr error)])]
      [else
        (IpErr
          (IpAddrError
            (IpInvalidByteLength)
            (if (> n 16)
              16
              n)))])))

;: Return one IPv4 octet, trapping when `index` is outside `[0, 4)`.
(define (ipv4-octet [address : (& address Ipv4Addr)] [index : i64]) : u8
  (array-ref address.octets index))

;: Return one IPv6 segment, trapping when `index` is outside `[0, 8)`.
(define (ipv6-segment [address : (& address Ipv6Addr)] [index : i64]) : u16
  (let
    [byte-index : i64 (* index 2)]
    [high : i64 (cast (array-ref address.octets byte-index) : i64)]
    [low : i64 (cast (array-ref address.octets (+ byte-index 1)) : i64)]
    (cast (+ (shl high 8) low) : u16)))

;: Return a by-value copy of the four authoritative network-order octets.
(define (ipv4-octets [address : (& address Ipv4Addr)]) : (Array u8 4)
  address.octets)

;: Return a by-value copy of the sixteen authoritative network-order octets.
(define (ipv6-octets [address : (& address Ipv6Addr)]) : (Array u8 16)
  address.octets)

;: Return true when two IPv4 addresses contain identical octets.
(define (ipv4-eq? [left : (& left Ipv4Addr)] [right : (& right Ipv4Addr)]) : bool
  (let
    [index : i64 0]
    [same : bool true]
    (begin
      (while (and same (< index 4))
        (begin
          (if (!= (array-ref left.octets index) (array-ref right.octets index))
            (set! same false)
            unit)
          (set! index (+ index 1))))
      same)))

;: Return true when two IPv6 addresses contain identical octets.
(define (ipv6-eq? [left : (& left Ipv6Addr)] [right : (& right Ipv6Addr)]) : bool
  (let
    [index : i64 0]
    [same : bool true]
    (begin
      (while (and same (< index 16))
        (begin
          (if (!= (array-ref left.octets index) (array-ref right.octets index))
            (set! same false)
            unit)
          (set! index (+ index 1))))
      same)))

;: Return true when two addresses have the same family and bytes.
(define (ip-eq? [left : (& left IpAddr)] [right : (& right IpAddr)]) : bool
  (match left
    [(V4 left-v4)
      (match right
        [(V4 right-v4) (ipv4-eq? (& left-v4) (& right-v4))]
        [(V6 _) false])]
    [(V6 left-v6)
      (match right
        [(V4 _) false]
        [(V6 right-v6) (ipv6-eq? (& left-v6) (& right-v6))])]))

;: Compare two IPv4 addresses lexicographically by network-order octets.
(define (ipv4-compare [left : (& left Ipv4Addr)] [right : (& right Ipv4Addr)]) : i64
  (let
    [index : i64 0]
    (begin
      (while (< index 4)
        (let
          [a : u8 (array-ref left.octets index)]
          [b : u8 (array-ref right.octets index)]
          (begin
            (when (< a b) (return -1))
            (when (> a b) (return 1))
            (set! index (+ index 1)))))
      0)))

;: Compare two IPv6 addresses lexicographically by network-order octets.
(define (ipv6-compare [left : (& left Ipv6Addr)] [right : (& right Ipv6Addr)]) : i64
  (let
    [index : i64 0]
    (begin
      (while (< index 16)
        (let
          [a : u8 (array-ref left.octets index)]
          [b : u8 (array-ref right.octets index)]
          (begin
            (when (< a b) (return -1))
            (when (> a b) (return 1))
            (set! index (+ index 1)))))
      0)))

;: Compare addresses by family (`V4` first), then network-order octets.
(define (ip-compare [left : (& left IpAddr)] [right : (& right IpAddr)]) : i64
  (match left
    [(V4 left-v4)
      (match right
        [(V4 right-v4) (ipv4-compare (& left-v4) (& right-v4))]
        [(V6 _) -1])]
    [(V6 left-v6)
      (match right
        [(V4 _) 1]
        [(V6 right-v6) (ipv6-compare (& left-v6) (& right-v6))])]))

;: Return a deterministic non-cryptographic IPv4 hash.
(define (ipv4-hash [address : (& address Ipv4Addr)]) : i64
  (let
    [value : i64 4]
    [index : i64 0]
    (begin
      (while (< index 4)
        (begin
          (set!
            value
            (hash.combine value (cast (array-ref address.octets index) : i64)))
          (set! index (+ index 1))))
      value)))

;: Return a deterministic non-cryptographic IPv6 hash.
(define (ipv6-hash [address : (& address Ipv6Addr)]) : i64
  (let
    [value : i64 6]
    [index : i64 0]
    (begin
      (while (< index 16)
        (begin
          (set!
            value
            (hash.combine value (cast (array-ref address.octets index) : i64)))
          (set! index (+ index 1))))
      value)))

;: Return a deterministic family-sensitive non-cryptographic IP hash.
(define (ip-hash [address : (& address IpAddr)]) : i64
  (match address
    [(V4 value) (hash.combine 4 (ipv4-hash (& value)))]
    [(V6 value) (hash.combine 6 (ipv6-hash (& value)))]))

;: Return an ASCII decimal digit value, or -1 for a non-digit.
(define (decimal-digit [ch : char]) : i64
  (if (and (>= ch '0') (<= ch '9'))
    (- (cast ch : i64) (cast '0' : i64))
    -1))

;: Return an ASCII hexadecimal digit value, or -1 for a non-digit.
(define (hex-digit [ch : char]) : i64
  (cond
    [(and (>= ch '0') (<= ch '9')) (- (cast ch : i64) (cast '0' : i64))]
    [(and (>= ch 'a') (<= ch 'f')) (+ 10 (- (cast ch : i64) (cast 'a' : i64)))]
    [(and (>= ch 'A') (<= ch 'F')) (+ 10 (- (cast ch : i64) (cast 'A' : i64)))]
    [else -1]))

;: Parse a strict dotted IPv4 range using absolute error offsets.
(define (parse-ipv4-range [text : (& text str)] [start : i64] [end : i64]) : Ipv4AddrResult
  (let
    [octets : (Array u8 4) (init)]
    [component : i64 0]
    [cursor : i64 start]
    (begin
      (while (< component 4)
        (begin
          (when
            (>= cursor end)
            (return (Ipv4Err (IpAddrError (IpTooFewComponents) end))))
          (let
            [component-start : i64 cursor]
            [first : i64 (decimal-digit (string-ref text cursor))]
            [value : i64 0]
            (begin
              (when
                (< first 0)
                (return (Ipv4Err (IpAddrError (IpInvalidCharacter) cursor))))
              (while (and (< cursor end) (!= (string-ref text cursor) '.'))
                (let
                  [digit : i64 (decimal-digit (string-ref text cursor))]
                  (begin
                    (when
                      (< digit 0)
                      (return
                        (Ipv4Err (IpAddrError (IpInvalidCharacter) cursor))))
                    (when
                      (and (= cursor (+ component-start 1)) (= first 0))
                      (return (Ipv4Err (IpAddrError (IpLeadingZero) cursor))))
                    (set! value (+ (* value 10) digit))
                    (when
                      (> value 255)
                      (return
                        (Ipv4Err (IpAddrError (IpComponentOverflow) cursor))))
                    (set! cursor (+ cursor 1)))))
              (set! (array-ref octets component) (cast value : u8))
              (if (< component 3)
                (if (and (< cursor end) (= (string-ref text cursor) '.'))
                  (set! cursor (+ cursor 1))
                  (return (Ipv4Err (IpAddrError (IpTooFewComponents) cursor))))
                (when
                  (< cursor end)
                  (return (Ipv4Err (IpAddrError (IpTooManyComponents) cursor)))))
              (set! component (+ component 1))))))
      (Ipv4Ok (Ipv4Addr octets)))))

;: Parse strict RFC 3986 dotted-decimal IPv4 text without allocating.
(define (parse-ipv4 [text : (& text str)]) : Ipv4AddrResult
  (let
    [n : i64 (string-length text)]
    (cond
      [(= n 0) (Ipv4Err (IpAddrError (IpEmpty) 0))]
      [(> n (ipv4-max-text-bytes))
        (Ipv4Err (IpAddrError (IpInputTooLong) (ipv4-max-text-bytes)))]
      [else (parse-ipv4-range text 0 n)])))

;: Return true when `[start, end)` contains a dot.
(define (range-has-dot? [text : (& text str)] [start : i64] [end : i64]) : bool
  (let
    [cursor : i64 start]
    [found : bool false]
    (begin
      (while (and (not found) (< cursor end))
        (begin
          (if (= (string-ref text cursor) '.')
            (set! found true)
            unit)
          (set! cursor (+ cursor 1))))
      found)))

;: Parse one IPv6 colon-delimited side without allocating.
(define (parse-ipv6-part
  [text : (& text str)]
  [start : i64]
  [end : i64]
  [allow-embedded-ipv4 : bool]) : Ipv6PartResult
  (let
    [segments : (Array u16 8) (init)]
    [count : i64 0]
    [token-start : i64 start]
    (begin
      (when (= start end) (return (Ipv6PartOk (Ipv6Part segments 0))))
      (while (< token-start end)
        (let
          [token-end : i64 token-start]
          (begin
            (while (and (< token-end end) (!= (string-ref text token-end) ':'))
              (set! token-end (+ token-end 1)))
            (when
              (= token-start token-end)
              (return
                (Ipv6PartErr (IpAddrError (IpInvalidSeparator) token-start))))
            (if (range-has-dot? text token-start token-end)
              (begin
                (when
                  (not allow-embedded-ipv4)
                  (return
                    (Ipv6PartErr
                      (IpAddrError (IpEmbeddedIpv4NotFinal) token-start))))
                (when
                  (!= token-end end)
                  (return
                    (Ipv6PartErr
                      (IpAddrError (IpEmbeddedIpv4NotFinal) token-end))))
                (when
                  (> count 6)
                  (return
                    (Ipv6PartErr
                      (IpAddrError (IpTooManyComponents) token-start))))
                (match (parse-ipv4-range text token-start token-end)
                  [(Ipv4Err error) (return (Ipv6PartErr error))]
                  [(Ipv4Ok address)
                    (begin
                      (set!
                        (array-ref segments count)
                        (cast
                          (+
                            (shl (cast (ipv4-octet (& address) 0) : i64) 8)
                            (cast (ipv4-octet (& address) 1) : i64))
                          : u16))
                      (set!
                        (array-ref segments (+ count 1))
                        (cast
                          (+
                            (shl (cast (ipv4-octet (& address) 2) : i64) 8)
                            (cast (ipv4-octet (& address) 3) : i64))
                          : u16))
                      (set! count (+ count 2)))])
                (set! token-start token-end))
              (let
                [cursor : i64 token-start]
                [value : i64 0]
                (begin
                  (when
                    (>= count 8)
                    (return
                      (Ipv6PartErr
                        (IpAddrError (IpTooManyComponents) token-start))))
                  (while (< cursor token-end)
                    (let
                      [digit : i64 (hex-digit (string-ref text cursor))]
                      (begin
                        (when
                          (< digit 0)
                          (return
                            (Ipv6PartErr
                              (IpAddrError (IpInvalidCharacter) cursor))))
                        (when
                          (>= (- cursor token-start) 4)
                          (return
                            (Ipv6PartErr
                              (IpAddrError (IpComponentOverflow) cursor))))
                        (set! value (+ (shl value 4) digit))
                        (set! cursor (+ cursor 1)))))
                  (set! (array-ref segments count) (cast value : u16))
                  (set! count (+ count 1)))))
            (if (= token-end end)
              (set! token-start end)
              (begin
                (set! token-start (+ token-end 1))
                (when
                  (= token-start end)
                  (return
                    (Ipv6PartErr (IpAddrError (IpInvalidSeparator) token-end)))))))))
      (Ipv6PartOk (Ipv6Part segments count)))))

;: Parse RFC 4291 IPv6 text without allocating.
(define (parse-ipv6 [text : (& text str)]) : Ipv6AddrResult
  (let
    [n : i64 (string-length text)]
    [cursor : i64 0]
    [compression : i64 -1]
    (begin
      (when (= n 0) (return (Ipv6Err (IpAddrError (IpEmpty) 0))))
      (when
        (> n (ipv6-max-text-bytes))
        (return (Ipv6Err (IpAddrError (IpInputTooLong) (ipv6-max-text-bytes)))))
      (while (< (+ cursor 1) n)
        (begin
          (if (and
            (= (string-ref text cursor) ':')
            (= (string-ref text (+ cursor 1)) ':'))
            (if (>= compression 0)
              (return (Ipv6Err (IpAddrError (IpMultipleCompression) cursor)))
              (begin
                (set! compression cursor)
                (set! cursor (+ cursor 1))))
            unit)
          (set! cursor (+ cursor 1))))
      (if (< compression 0)
        (match (parse-ipv6-part text 0 n true)
          [(Ipv6PartErr error) (Ipv6Err error)]
          [(Ipv6PartOk part)
            (if (!= part.count 8)
              (Ipv6Err (IpAddrError (IpTooFewComponents) n))
              (Ipv6Ok (ipv6-from-segments part.segments)))])
        (match (parse-ipv6-part text 0 compression false)
          [(Ipv6PartErr error) (Ipv6Err error)]
          [(Ipv6PartOk left)
            (match (parse-ipv6-part text (+ compression 2) n true)
              [(Ipv6PartErr error) (Ipv6Err error)]
              [(Ipv6PartOk right)
                (let
                  [total : i64 (+ left.count right.count)]
                  [zeros : i64 (- 8 total)]
                  [segments : (Array u16 8) (init)]
                  [index : i64 0]
                  (begin
                    (when
                      (< zeros 0)
                      (return
                        (Ipv6Err
                          (IpAddrError (IpTooManyComponents) compression))))
                    (when
                      (= zeros 0)
                      (return
                        (Ipv6Err
                          (IpAddrError (IpCompressionWithoutZero) compression))))
                    (while (< index left.count)
                      (begin
                        (set!
                          (array-ref segments index)
                          (array-ref left.segments index))
                        (set! index (+ index 1))))
                    (set! index 0)
                    (while (< index right.count)
                      (begin
                        (set!
                          (array-ref segments (+ (+ left.count zeros) index))
                          (array-ref right.segments index))
                        (set! index (+ index 1))))
                    (Ipv6Ok (ipv6-from-segments segments))))])])))))

;: Parse IPv4 when no colon occurs, otherwise parse IPv6.
(define (parse-ip [text : (& text str)]) : IpAddrResult
  (let
    [n : i64 (string-length text)]
    [cursor : i64 0]
    [has-colon : bool false]
    (begin
      (while (and (not has-colon) (< cursor n))
        (begin
          (if (= (string-ref text cursor) ':')
            (set! has-colon true)
            unit)
          (set! cursor (+ cursor 1))))
      (if has-colon
        (match (parse-ipv6 text)
          [(Ipv6Ok address) (IpOk (V6 address))]
          [(Ipv6Err error) (IpErr error)])
        (match (parse-ipv4 text)
          [(Ipv4Ok address) (IpOk (V4 address))]
          [(Ipv4Err error) (IpErr error)])))))

;: Format an IPv4 address to strict minimal dotted decimal.
(define (ipv4-to-string [address : (& address Ipv4Addr)]) : String
  (let
    [storage : (Array u8 15) (init)]
    [output : (MutPtr u8)
      (unsafe
        (ptr-cast (__tl_array-data storage) : (MutPtr u8)))]
    [cursor : i64 0]
    [index : i64 0]
    (begin
      (while (< index 4)
        (let
          [number : i64 (cast (array-ref address.octets index) : i64)]
          (begin
            (if (> index 0)
              (begin
                (unsafe
                  (ptr-write! (ptr-offset output cursor) (cast '.' : u8)))
                (set! cursor (+ cursor 1)))
              unit)
            (if (>= number 100)
              (begin
                (unsafe
                  (ptr-write!
                    (ptr-offset output cursor)
                    (cast (+ 48 (/ number 100)) : u8)))
                (set! cursor (+ cursor 1))
                (set! number (% number 100))
                (unsafe
                  (ptr-write!
                    (ptr-offset output cursor)
                    (cast (+ 48 (/ number 10)) : u8)))
                (set! cursor (+ cursor 1))
                (unsafe
                  (ptr-write!
                    (ptr-offset output cursor)
                    (cast (+ 48 (% number 10)) : u8)))
                (set! cursor (+ cursor 1)))
              (if (>= number 10)
                (begin
                  (unsafe
                    (ptr-write!
                      (ptr-offset output cursor)
                      (cast (+ 48 (/ number 10)) : u8)))
                  (set! cursor (+ cursor 1))
                  (unsafe
                    (ptr-write!
                      (ptr-offset output cursor)
                      (cast (+ 48 (% number 10)) : u8)))
                  (set! cursor (+ cursor 1)))
                (begin
                  (unsafe
                    (ptr-write!
                      (ptr-offset output cursor)
                      (cast (+ 48 number) : u8)))
                  (set! cursor (+ cursor 1)))))
            (set! index (+ index 1)))))
      (let
        [finished : (MutPtr u8) (string.string-runtime-alloc cursor)]
        [copy-index : i64 0]
        (begin
          (while (< copy-index cursor)
            (begin
              (unsafe
                (ptr-write!
                  (ptr-offset finished copy-index)
                  (ptr-read (ptr-offset output copy-index))))
              (set! copy-index (+ copy-index 1))))
          (unsafe
            (string-from-bytes (ptr-cast finished : (Ptr u8)) cursor)))))))

;: Format an IPv6 address to the canonical pure-hexadecimal RFC 5952 spelling.
(define (ipv6-to-string [address : (& address Ipv6Addr)]) : String
  (let
    [best-start : i64 -1]
    [best-length : i64 0]
    [index : i64 0]
    (begin
      (while (< index 8)
        (if (= (ipv6-segment address index) (cast 0 : u16))
          (let
            [run-start : i64 index]
            (begin
              (while (and
                (< index 8)
                (= (ipv6-segment address index) (cast 0 : u16)))
                (set! index (+ index 1)))
              (let
                [run-length : i64 (- index run-start)]
                (if (and (> run-length best-length) (>= run-length 2))
                  (begin
                    (set! best-start run-start)
                    (set! best-length run-length))
                  unit))))
          (set! index (+ index 1))))
      (let
        [storage : (Array u8 39) (init)]
        [output : (MutPtr u8)
          (unsafe
            (ptr-cast (__tl_array-data storage) : (MutPtr u8)))]
        [cursor : i64 0]
        [segment-index : i64 0]
        (begin
          (while (< segment-index 8)
            (if (= segment-index best-start)
              (begin
                (unsafe
                  (ptr-write! (ptr-offset output cursor) (cast ':' : u8)))
                (set! cursor (+ cursor 1))
                (unsafe
                  (ptr-write! (ptr-offset output cursor) (cast ':' : u8)))
                (set! cursor (+ cursor 1))
                (set! segment-index (+ segment-index best-length)))
              (begin
                (if (and
                  (> segment-index 0)
                  (not (= segment-index (+ best-start best-length))))
                  (begin
                    (unsafe
                      (ptr-write! (ptr-offset output cursor) (cast ':' : u8)))
                    (set! cursor (+ cursor 1)))
                  unit)
                (let
                  [value : i64
                    (cast (ipv6-segment address segment-index) : i64)]
                  [shift : i64 12]
                  [started : bool false]
                  (while (>= shift 0)
                    (let
                      [digit : i64 (bit-and (shr value shift) 15)]
                      (begin
                        (if (or started (!= digit 0) (= shift 0))
                          (begin
                            (set! started true)
                            (unsafe
                              (ptr-write!
                                (ptr-offset output cursor)
                                (if (< digit 10)
                                  (cast (+ 48 digit) : u8)
                                  (cast (+ 87 digit) : u8))))
                            (set! cursor (+ cursor 1)))
                          unit)
                        (set! shift (- shift 4))))))
                (set! segment-index (+ segment-index 1)))))
          (let
            [finished : (MutPtr u8) (string.string-runtime-alloc cursor)]
            [copy-index : i64 0]
            (begin
              (while (< copy-index cursor)
                (begin
                  (unsafe
                    (ptr-write!
                      (ptr-offset finished copy-index)
                      (ptr-read (ptr-offset output copy-index))))
                  (set! copy-index (+ copy-index 1))))
              (unsafe
                (string-from-bytes (ptr-cast finished : (Ptr u8)) cursor)))))))))

;: Format either address family to its canonical text spelling.
(define (ip-to-string [address : (& address IpAddr)]) : String
  (match address
    [(V4 value) (ipv4-to-string (& value))]
    [(V6 value) (ipv6-to-string (& value))]))

(test
  net-ip-canonical-codec
  (let
    [v4-source : String "192.0.2.128"]
    [v6-source : String "2001:0DB8:0:0:0:0:0:1"]
    (begin
      (match (parse-ipv4 (& v4-source))
        [(Ipv4Err _)
          (begin
            (/ 1 0)
            unit)]
        [(Ipv4Ok address)
          (let
            [actual : String (ipv4-to-string (& address))]
            (if (string.eq (& actual) (& v4-source))
              unit
              (begin
                (/ 1 0)
                unit)))])
      (match (parse-ipv6 (& v6-source))
        [(Ipv6Err _)
          (begin
            (/ 1 0)
            unit)]
        [(Ipv6Ok address)
          (let
            [actual : String (ipv6-to-string (& address))]
            (if (string.eq (& actual) "2001:db8::1")
              unit
              (begin
                (/ 1 0)
                unit)))])
      (let
        [bad : String "192.168.001.1"]
        (match (parse-ipv4 (& bad))
          [(Ipv4Ok _)
            (begin
              (/ 1 0)
              unit)]
          [(Ipv4Err error)
            (if (= error.offset 9)
              unit
              (begin
                (/ 1 0)
                unit))])))))