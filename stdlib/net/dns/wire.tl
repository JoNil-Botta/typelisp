;# Pure, bounded DNS stub-resolver message codec (RFC 1035, 6672 and 6891).
;#
;# `encode-query` writes one IN/A or IN/AAAA question with optional EDNS0
;# advertising 1232 bytes. `decode-response` returns either a fully validated
;# `DnsComplete` or a `DnsTruncated` containing only the header and question.
;# TC packets need no complete RR bytes after that envelope. Authentication,
;# transport, retries, CNAME policy and caching belong to the resolver.
;#
;# Names use lowercase ASCII length-prefixed wire bytes, including their root
;# terminator. Label contents remain distinct even when they contain a dot.
;# Text input accepts ASCII labels separated by dots, with at most one final
;# dot; empty text and `.` denote the root. No Unicode or IDNA is accepted.
;# Compression targets must be backward, previously validated label boundaries.
;# IN name fields (including skipped NS/MD/MF/MB/MG/MR/PTR/MINFO/MX and DNAME
;# records) are validated under the same bounds so later names can reference
;# them. DNAME targets must be literal (RFC 6672 section 2.5). Their record
;# values remain unreturned. Other opaque RDATA is never scanned for speculative
;# names. Each hop must precede the current expansion
;# start, rejecting cycles even when a pointer follows literal labels.
;# Non-ASCII bytes in any decoded name, including skipped-record names and
;# owners of unrelated records, reject the message under the ASCII-only policy.
;#
;# Hard bounds: 65535 input bytes, 256 RRs, 256 decoded names, 4096 total
;# compression hops, 32 hops/name, 64 addresses, 127 labels/name, 255 expanded
;# wire bytes/name, and 253 text bytes excluding one final dot. Bounds are
;# checked before allocation/access. Malformed input and limits are distinct.
;# Storage is at most 16384 boundary bytes plus 256 fixed-size record slots;
;# expansion work is at most 256 * 255 label bytes and 4096 pointer hops.
;# Unknown types/classes retain no RDATA. Every declared byte must be consumed
;# for Complete, and no partial result escapes on failure.
;#
;# Usage: `(import stdlib.net.dns.wire)`.
;#
;# ```typelisp
;# (import stdlib.byte_buf)
;# (import stdlib.net.dns.wire)
;# (define (main) : i64
;#   (match (wire.encode-query "." 28 4660 true true)
;#     [(DnsQueryOk query) (if (= (byte_buf.len (& query)) 28) 0 1)]
;#     [(DnsQueryErr _) 1]))
;# ```
(import stdlib.byte_buf)
(import stdlib.string)

;: Stable failure categories; protocol/resource bounds use DnsLimitExceeded.
(defenum DnsErrorKind
  (DnsMalformed)
  (DnsLimitExceeded))

;: First failure and its byte offset in the supplied message or text.
(defstruct DnsError
  (kind DnsErrorKind)
  (offset i64))

;: Canonical length-prefixed ASCII name; only the first `len` bytes are live.
(defstruct DnsName
  (octets (Array u8 255))
  (len i64))

;: Name validation result.
(defenum DnsNameResult
  (DnsNameOk DnsName)
  (DnsNameErr DnsError))

;: Query encoding result. Invalid query types are malformed input.
(defenum DnsQueryResult
  (DnsQueryOk byte_buf.ByteBuf)
  (DnsQueryErr DnsError))

;: Exact DNS header fields, with flags retained for later authentication.
(defstruct DnsHeader
  (id u16)
  (flags u16)
  (questions i64)
  (answers i64)
  (authorities i64)
  (additionals i64))

;: One complete canonical question, including exact type and class.
(defstruct DnsQuestion
  (name DnsName)
  (qtype u16)
  (qclass u16))

;: Validated header and question. A TC result contains no RR storage.
(defstruct DnsEnvelope
  (header DnsHeader)
  (question DnsQuestion))

;: SOA fields; unsigned 32-bit wire integers are zero-extended into i64.
(defstruct DnsSoa
  (primary DnsName)
  (mailbox DnsName)
  (serial i64)
  (refresh i64)
  (retry i64)
  (expire i64)
  (minimum i64))

;: OPT metadata. Options are checked as length-delimited tuples and skipped.
(defstruct DnsOpt
  (udp-bytes u16)
  (extended-rcode u8)
  (version u8)
  (flags u16))

;: Supported typed RDATA. Addresses retain exact network-order bytes.
(defenum DnsRecordData
  (DnsA (Array u8 4))
  (DnsAaaa (Array u8 16))
  (DnsCname DnsName)
  (DnsSoaData DnsSoa)
  (DnsOptData DnsOpt))

;: Typed record in original order; section 0=answer, 1=authority, 2=additional.
(defstruct DnsRecord
  (owner DnsName)
  (ttl i64)
  (section i64)
  (data DnsRecordData))

;: Complete response. Only the first `len` record slots are live. The backing
;: array's length is capacity, not a record count: never inspect its padding.
(defstruct DnsMessage
  (envelope DnsEnvelope)
  (records (__tl_dyn-array DnsRecord))
  (len i64))

;: No record can be observed from a failed or truncated response.
(defenum DnsResponseResult
  (DnsComplete DnsMessage)
  (DnsTruncated DnsEnvelope)
  (DnsResponseErr DnsError))

;: Internal checked cursor and shared name/work budgets.
(defstruct Decoder
  (offset i64)
  (end i64)
  (failed bool)
  (limit bool)
  (error-offset i64)
  (names i64)
  (hops i64)
  (addresses i64)
  (opt-seen bool)
  (boundaries (__tl_dyn-array u8)))

;: Construct the canonical root without allocating.
(define (root-name) : DnsName
  (DnsName (make-array u8 255) 1))

;: Fold only ASCII A-Z.
(define (lower [octet : u8]) : u8
  (if (and (>= octet 65) (<= octet 90))
    (+ octet 32)
    octet))

;: Validate text and canonicalize labels, without Unicode or IDNA processing.
(define (parse-name [text : (& text str)]) : DnsNameResult
  (let
    [n : i64 (string.string-length text)]
    [end : i64 n]
    [out : DnsName (root-name)]
    [start : i64 0]
    [labels : i64 0]
    (when
      (and (> end 0) (= (string.string-ref text (- end 1)) '.'))
      (set! end (- end 1)))
    (when (> end 253) (return (DnsNameErr (DnsError (DnsLimitExceeded) 253))))
    (when (= end 0) (return (DnsNameOk out)))
    (set! out.len 0)
    (while (< start end)
      (let
        [stop : i64 start]
        (while (and (< stop end) (!= (string.string-ref text stop) '.'))
          (when
            (> (cast (string.string-ref text stop) : i64) 127)
            (return (DnsNameErr (DnsError (DnsMalformed) stop))))
          (set! stop (+ stop 1)))
        (let
          [count : i64 (- stop start)]
          (when
            (= count 0)
            (return (DnsNameErr (DnsError (DnsMalformed) start))))
          (when
            (or (> count 63) (>= labels 127) (> count (- 253 out.len)))
            (return (DnsNameErr (DnsError (DnsLimitExceeded) start))))
          (set! (array-ref out.octets out.len) (cast count : u8))
          (set! out.len (+ out.len 1))
          (let
            [index : i64 start]
            (while (< index stop)
              (set!
                (array-ref out.octets out.len)
                (lower (cast (string.string-ref text index) : u8)))
              (set! out.len (+ out.len 1))
              (set! index (+ index 1))))
          (set! labels (+ labels 1)))
        (when
          (and (< stop end) (= (+ stop 1) end))
          (return (DnsNameErr (DnsError (DnsMalformed) stop))))
        (set! start (+ stop 1))))
    (set! (array-ref out.octets out.len) 0)
    (set! out.len (+ out.len 1))
    (DnsNameOk out)))

;: Compare validated canonical wire names, including their label boundaries.
(define (name-eq? [left : (& left DnsName)] [right : (& right DnsName)]) : bool
  (when (!= left.len right.len) (return false))
  (let
    [i : i64 0]
    (while (< i left.len)
      (when
        (!= (array-ref left.octets i) (array-ref right.octets i))
        (return false))
      (set! i (+ i 1)))
    true))

;: Append a big-endian 16-bit integer.
(define (push-u16 [out : byte_buf.ByteBuf] [value : i64]) : byte_buf.ByteBuf
  (byte_buf.push
    (byte_buf.push out (cast (shr value 8) : u8))
    (cast (bit-and value 255) : u8)))

;: Encode one deterministic IN/A or IN/AAAA query, optionally adding EDNS0.
(define (encode-query
  [text : (& text str)]
  [qtype : u16]
  [id : u16]
  [rd : bool]
  [edns : bool]) : DnsQueryResult
  (when
    (and (!= qtype 1) (!= qtype 28))
    (return (DnsQueryErr (DnsError (DnsMalformed) 0))))
  (match (parse-name text)
    [(DnsNameErr error) (DnsQueryErr error)]
    [(DnsNameOk name)
      (let
        [out : byte_buf.ByteBuf (byte_buf.with-capacity (+ 27 name.len))]
        [i : i64 0]
        (set! out (push-u16 out (cast id : i64)))
        (set!
          out
          (push-u16
            out
            (if rd
              256
              0)))
        (set! out (push-u16 out 1))
        (set! out (push-u16 out 0))
        (set! out (push-u16 out 0))
        (set!
          out
          (push-u16
            out
            (if edns
              1
              0)))
        (while (< i name.len)
          (set! out (byte_buf.push out (array-ref name.octets i)))
          (set! i (+ i 1)))
        (set! out (push-u16 out (cast qtype : i64)))
        (set! out (push-u16 out 1))
        (when
          edns
          (set! out (byte_buf.push out 0))
          (set! out (push-u16 out 41))
          (set! out (push-u16 out 1232))
          (set! out (push-u16 out 0))
          (set! out (push-u16 out 0))
          (set! out (push-u16 out 0)))
        (DnsQueryOk out))]))

;: Record the first failure, preserving malformed/limit classification.
(define (fail! [d : (&mut d Decoder)] [limit : bool] [offset : i64]) : unit
  (when
    (not d.failed)
    (set! d.failed true)
    (set! d.limit limit)
    (set! d.error-offset offset)))

;: Check a range with subtraction before any offset addition or access.
(define (present? [end : i64] [start : i64] [count : i64]) : bool
  (and (>= start 0) (>= count 0) (<= start end) (<= count (- end start))))

;: Check the cursor's next field against its containing message/RDATA bound.
(define (require! [d : (&mut d Decoder)] [count : i64]) : bool
  (if d.failed
    false
    (if (present? d.end d.offset count)
      true
      (begin
        (fail! d false d.offset)
        false))))

;: Read a checked big-endian 16-bit field.
(define (read-u16! [d : (&mut d Decoder)] [input : (& input bytes)]) : i64
  (if (require! d 2)
    (let
      [p : i64 d.offset]
      (set! d.offset (+ p 2))
      (+
        (shl (cast (byte_buf.bytes-ref input p) : i64) 8)
        (cast (byte_buf.bytes-ref input (+ p 1)) : i64)))
    0))

;: Read a checked unsigned 32-bit wire integer as i64.
(define (read-u32! [d : (&mut d Decoder)] [input : (& input bytes)]) : i64
  (let
    [high : i64 (read-u16! d input)]
    [low : i64 (read-u16! d input)]
    (+ (shl high 16) low)))

;: Decode a name within the current field; pointer expansion uses message bounds.
(define (read-name!
  [d : (&mut d Decoder)]
  [input : (& input bytes)]
  [allow-compression : bool]) : DnsName
  (let
    [out : DnsName (root-name)]
    [p : i64 d.offset]
    [ceiling : i64 p]
    [field-end : i64 d.end]
    [hops : i64 0]
    [labels : i64 0]
    [jumped : bool false]
    [done : bool false]
    (when d.failed (return out))
    (when (>= d.names 256) (fail! d true p) (return out))
    (set! d.names (+ d.names 1))
    (set! out.len 0)
    (while (and (not d.failed) (not done))
      (let
        [bound : i64
          (if jumped
            (byte_buf.bytes-length input)
            field-end)]
        (when (not (present? bound p 1)) (fail! d false p) (return out))
        (let
          [tag : i64 (cast (byte_buf.bytes-ref input p) : i64)]
          (cond
            [(>= tag 192)
              (when (not allow-compression) (fail! d false p) (return out))
              (when (not (present? bound p 2)) (fail! d false p) (return out))
              (let
                [target : i64
                  (+
                    (shl (- tag 192) 8)
                    (cast (byte_buf.bytes-ref input (+ p 1)) : i64))]
                (when
                  (or (>= target ceiling) (= (array-ref d.boundaries target) 0))
                  (fail! d false p)
                  (return out))
                (when
                  (or (>= hops 32) (>= d.hops 4096))
                  (fail! d true p)
                  (return out))
                (when
                  (not jumped)
                  (when (< p 16384) (set! (array-ref d.boundaries p) 1))
                  (set! d.offset (+ p 2)))
                (set! jumped true)
                (set! hops (+ hops 1))
                (set! d.hops (+ d.hops 1))
                (set! ceiling target)
                (set! p target))]
            [(>= tag 64) (fail! d false p)]
            [else
              (when
                (not (present? bound (+ p 1) tag))
                (fail! d false p)
                (return out))
              (when
                (or
                  (and (> tag 0) (>= labels 127))
                  (> (+ tag 1) (- 255 out.len)))
                (fail! d true p)
                (return out))
              ;; Leave room for the root when this is a non-root label.
              (when
                (and (> tag 0) (> (+ tag 2) (- 255 out.len)))
                (fail! d true p)
                (return out))
              (when
                (and (not jumped) (< p 16384))
                (set! (array-ref d.boundaries p) 1))
              (set! (array-ref out.octets out.len) (cast tag : u8))
              (set! out.len (+ out.len 1))
              (let
                [j : i64 0]
                (while (< j tag)
                  (let
                    [octet : u8 (byte_buf.bytes-ref input (+ (+ p 1) j))]
                    (when
                      (> octet 127)
                      (fail! d false (+ (+ p 1) j))
                      (return out))
                    (set! (array-ref out.octets out.len) (lower octet))
                    (set! out.len (+ out.len 1)))
                  (set! j (+ j 1))))
              (set! p (+ (+ p 1) tag))
              (when (not jumped) (set! d.offset p))
              (if (= tag 0)
                (set! done true)
                (set! labels (+ labels 1)))]))))
    out))

;: Convert the internal sticky failure to a stable public error.
(define (decoder-error [d : (& d Decoder)]) : DnsError
  (DnsError
    (if d.limit
      (DnsLimitExceeded)
      (DnsMalformed))
    d.error-offset))

;: Number of domain-name fields in skipped IN RDATA. Legacy fields and literal
;: DNAME targets are validated for later compression references, although their
;: records are not returned. MX also has a two-byte preference.
(define (skipped-name-count [rtype : i64]) : i64
  (cond
    [(= rtype 14) 2]
    [(or
        (= rtype 2)
        (= rtype 3)
        (= rtype 4)
        (= rtype 7)
        (= rtype 8)
        (= rtype 9)
        (= rtype 12)
        (= rtype 15)
        (= rtype 39))
      1]
    [else 0]))

;: Decode and validate a complete message or return only its TC envelope.
(define (decode-response [input : (& input bytes)]) : DnsResponseResult
  (let
    [n : i64 (byte_buf.bytes-length input)]
    (when
      (> n 65535)
      (return (DnsResponseErr (DnsError (DnsLimitExceeded) 65535))))
    (when (< n 12) (return (DnsResponseErr (DnsError (DnsMalformed) n))))
    (let
      [d : Decoder
        (Decoder 0 n false false 0 0 0 0 false (__tl_make-array u8 16384))]
      [id : u16 (cast (read-u16! (&mut d) input) : u16)]
      [flags : u16 (cast (read-u16! (&mut d) input) : u16)]
      [qd : i64 (read-u16! (&mut d) input)]
      [an : i64 (read-u16! (&mut d) input)]
      [ns : i64 (read-u16! (&mut d) input)]
      [ar : i64 (read-u16! (&mut d) input)]
      (when (!= qd 1) (return (DnsResponseErr (DnsError (DnsMalformed) 4))))
      (let
        [name : DnsName (read-name! (&mut d) input true)]
        [qtype : u16 (cast (read-u16! (&mut d) input) : u16)]
        [qclass : u16 (cast (read-u16! (&mut d) input) : u16)]
        [envelope : DnsEnvelope
          (DnsEnvelope
            (DnsHeader id flags qd an ns ar)
            (DnsQuestion name qtype qclass))]
        (when d.failed (return (DnsResponseErr (decoder-error (& d)))))
        (when
          (!= (bit-and (cast flags : i64) 512) 0)
          (return (DnsTruncated envelope)))
        (let
          [total : i64 (+ (+ an ns) ar)]
          (when
            (> total 256)
            (return (DnsResponseErr (DnsError (DnsLimitExceeded) 6))))
          (let
            [records : (__tl_dyn-array DnsRecord)
              (__tl_make-array DnsRecord total)]
            [count : i64 0]
            [index : i64 0]
            (while (and (< index total) (not d.failed))
              (let
                [owner : DnsName (read-name! (&mut d) input true)]
                [rtype : i64 (read-u16! (&mut d) input)]
                [rclass : i64 (read-u16! (&mut d) input)]
                [ttl : i64 (read-u32! (&mut d) input)]
                [length : i64 (read-u16! (&mut d) input)]
                [section : i64
                  (if (< index an)
                    0
                    (if (< index (+ an ns))
                      1
                      2))]
                (when
                  (not (require! (&mut d) length))
                  (return (DnsResponseErr (decoder-error (& d)))))
                (let
                  [end : i64 (+ d.offset length)]
                  [known : bool
                    (or
                      (= rtype 41)
                      (and
                        (= rclass 1)
                        (or (= rtype 1) (= rtype 28) (= rtype 5) (= rtype 6))))]
                  [skipped-names : i64
                    (if (= rclass 1)
                      (skipped-name-count rtype)
                      0)]
                  (set! d.end end)
                  (let
                    [data : DnsRecordData
                      (cond
                        [(and (= rclass 1) (or (= rtype 1) (= rtype 28)))
                          (let
                            [expected : i64
                              (if (= rtype 1)
                                4
                                16)]
                            (when
                              (!= length expected)
                              (fail! (&mut d) false d.offset))
                            (when
                              (>= d.addresses 64)
                              (fail! (&mut d) true d.offset))
                            (when
                              (not d.failed)
                              (set! d.addresses (+ d.addresses 1)))
                            (let
                              [octets : (Array u8 16) (make-array u8 16)]
                              [j : i64 0]
                              (while (and (< j expected) (not d.failed))
                                (set!
                                  (array-ref octets j)
                                  (byte_buf.bytes-ref input d.offset))
                                (set! d.offset (+ d.offset 1))
                                (set! j (+ j 1)))
                              (if (= expected 4)
                                (DnsA
                                  (array
                                    (array-ref octets 0)
                                    (array-ref octets 1)
                                    (array-ref octets 2)
                                    (array-ref octets 3)))
                                (DnsAaaa octets))))]
                        [(and (= rclass 1) (= rtype 5))
                          (DnsCname (read-name! (&mut d) input true))]
                        [(and (= rclass 1) (= rtype 6))
                          (let
                            [primary : DnsName (read-name! (&mut d) input true)]
                            [mailbox : DnsName (read-name! (&mut d) input true)]
                            [serial : i64 (read-u32! (&mut d) input)]
                            [refresh : i64 (read-u32! (&mut d) input)]
                            [retry : i64 (read-u32! (&mut d) input)]
                            [expire : i64 (read-u32! (&mut d) input)]
                            [minimum : i64 (read-u32! (&mut d) input)]
                            (DnsSoaData
                              (DnsSoa
                                primary
                                mailbox
                                serial
                                refresh
                                retry
                                expire
                                minimum)))]
                        [(= rtype 41)
                          (when
                            (or (!= section 2) (!= owner.len 1) d.opt-seen)
                            (fail! (&mut d) false d.offset))
                          (set! d.opt-seen true)
                          (while (and (< d.offset end) (not d.failed))
                            (let
                              [_code : i64 (read-u16! (&mut d) input)]
                              [option-length : i64 (read-u16! (&mut d) input)]
                              (when
                                (require! (&mut d) option-length)
                                (set! d.offset (+ d.offset option-length)))
                              unit))
                          (DnsOptData
                            (DnsOpt
                              (cast rclass : u16)
                              (cast (shr ttl 24) : u8)
                              (cast (bit-and (shr ttl 16) 255) : u8)
                              (cast (bit-and ttl 65535) : u16)))]
                        [(> skipped-names 0)
                          (when
                            (= rtype 15)
                            (let
                              [_preference : i64 (read-u16! (&mut d) input)]
                              unit))
                          (let
                            [name-index : i64 0]
                            (while (and
                              (< name-index skipped-names)
                              (not d.failed))
                              (let
                                [_name : DnsName
                                  (read-name! (&mut d) input (!= rtype 39))]
                                unit)
                              (set! name-index (+ name-index 1))))
                          (DnsCname (root-name))]
                        [else
                          (set! d.offset end)
                          (DnsCname (root-name))])]
                    (when
                      (and (not d.failed) (!= d.offset end))
                      (fail! (&mut d) false d.offset))
                    (when
                      (and known (not d.failed))
                      (set!
                        (array-ref records count)
                        (DnsRecord owner ttl section data))
                      (set! count (+ count 1))))
                  (set! d.end n)))
              (set! index (+ index 1)))
            (when d.failed (return (DnsResponseErr (decoder-error (& d)))))
            (if (!= d.offset n)
              (DnsResponseErr (DnsError (DnsMalformed) d.offset))
              (DnsComplete (DnsMessage envelope records count)))))))))