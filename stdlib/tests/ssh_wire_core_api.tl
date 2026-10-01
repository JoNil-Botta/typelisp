(import stdlib.byte_buf)
(import stdlib.ssh_wire_core as wire)
(import stdlib.test)

;; --- helpers -------------------------------------------------------------------
(define (hex-value [code : i64]) : i64
  (cond
    [(and (>= code 48) (<= code 57)) (- code 48)]
    [(and (>= code 97) (<= code 102)) (+ 10 (- code 97))]
    [(and (>= code 65) (<= code 70)) (+ 10 (- code 65))]
    [else -1]))

;; The bytes of `text`'s hex digit pairs; any other character separates.
(define (hex [text : String]) : byte_buf.ByteBuf
  (let
    [view : (& text bytes) (byte_buf.str-as-bytes (& text))]
    [count : i64 (byte_buf.bytes-length view)]
    [out : byte_buf.ByteBuf (byte_buf.new)]
    [index : i64 0]
    [high : i64 -1]
    (begin
      (while (< index count)
        (let
          [value : i64 (hex-value (cast (byte_buf.bytes-ref view index) : i64))]
          (begin
            (when
              (>= value 0)
              (if (< high 0)
                (set! high value)
                (begin
                  (set!
                    out
                    (byte_buf.push out (cast (+ (* high 16) value) : u8)))
                  (set! high -1))))
            (set! index (+ index 1)))))
      out)))

(define (bytes-eq? [left : (& left bytes)] [right : (& right bytes)]) : bool
  (let
    [count : i64 (byte_buf.bytes-length left)]
    [same : bool (= count (byte_buf.bytes-length right))]
    [index : i64 0]
    (begin
      (while (and same (< index count))
        (begin
          (when
            (!=
              (byte_buf.bytes-ref left index)
              (byte_buf.bytes-ref right index))
            (set! same false))
          (set! index (+ index 1))))
      same)))

(define (assert-bytes
  [actual : (& actual bytes)]
  [expected : String]
  [message : String]) : unit
  (let
    [want : byte_buf.ByteBuf (hex expected)]
    (test.assert-true (bytes-eq? actual (byte_buf.as-bytes (& want))) message)))

(define (assert-text
  [actual : (& actual bytes)]
  [expected : String]
  [message : String]) : unit
  (test.assert-true
    (bytes-eq? actual (byte_buf.str-as-bytes (& expected)))
    message))

;; A deterministic 31-bit linear congruential generator for the fuzz gates.
(define (lcg [state : i64]) : i64
  (% (+ (* state 1103515245) 12345) 2147483648))

(define (small-limits) : wire.SshWireLimits
  (wire.SshWireLimits 255 4 64 128 4096 32 64 4 16))

;; --- primitives -----------------------------------------------------------------
(define (assert-fixed-width) : unit
  (let
    [buf : byte_buf.ByteBuf
      (hex
        "00 7f ff 00 01 02 29 b7 f4 aa ff ff ff ff 00 00 00 00 00 00 00 00 ff ff ff ff ff ff ff ff 01 02 03 04 05 06 07 08")]
    [view : (& buf bytes) (byte_buf.as-bytes (& buf))]
    [d : wire.SshDecoder (wire.decoder-new view)]
    (begin
      (test.assert-i64-eq (wire.decoder-byte! (&mut d) view) 0 "byte 00")
      (test.assert-i64-eq (wire.decoder-byte! (&mut d) view) 127 "byte 7f")
      (test.assert-i64-eq (wire.decoder-byte! (&mut d) view) 255 "byte ff")
      (test.assert-false (wire.decoder-boolean! (&mut d) view) "boolean 0")
      (test.assert-true (wire.decoder-boolean! (&mut d) view) "boolean 1")
      (test.assert-true
        (wire.decoder-boolean! (&mut d) view)
        "RFC 4251 reads a non-zero boolean as TRUE")
      ;; RFC 4251 section 5: the value 699921578 is 29 b7 f4 aa.
      (test.assert-i64-eq
        (wire.decoder-uint32! (&mut d) view)
        699921578
        "uint32 RFC")
      (test.assert-i64-eq
        (wire.decoder-uint32! (&mut d) view)
        4294967295
        "uint32 max")
      (test.assert-true
        (= (wire.decoder-uint64! (&mut d) view) (cast 0 : u64))
        "uint64 zero")
      (test.assert-true
        (= (wire.decoder-uint64! (&mut d) view) (cast -1 : u64))
        "uint64 max")
      (test.assert-true
        (= (wire.decoder-uint64! (&mut d) view) (cast 72623859790382856 : u64))
        "uint64 order")
      (wire.decoder-finish! (&mut d))
      (test.assert-false d.failed "fixed-width reads consume the view")
      (let
        [out : byte_buf.ByteBuf
          (wire.push-uint64
            (wire.push-uint64
              (wire.push-uint64
                (wire.push-uint32
                  (wire.push-uint32
                    (wire.push-boolean
                      (wire.push-boolean
                        (wire.push-boolean
                          (wire.push-byte
                            (wire.push-byte
                              (wire.push-byte (byte_buf.new) 0)
                              127)
                            255)
                          false)
                        true)
                      true)
                    699921578)
                  4294967295)
                (cast 0 : u64))
              (cast -1 : u64))
            (cast 72623859790382856 : u64))]
        (assert-bytes
          (byte_buf.as-bytes (& out))
          "00 7f ff 00 01 01 29 b7 f4 aa ff ff ff ff 00 00 00 00 00 00 00 00 ff ff ff ff ff ff ff ff 01 02 03 04 05 06 07 08"
          "fixed-width encoders, a TRUE boolean as 01")))))

(define (assert-strings) : unit
  (let
    [buf : byte_buf.ByteBuf
      (hex "00 00 00 07 74 65 73 74 69 6e 67 00 00 00 00 00 00 00 03 00 ff 0a")]
    [view : (& buf bytes) (byte_buf.as-bytes (& buf))]
    [d : wire.SshDecoder (wire.decoder-new view)]
    [testing : wire.SshSpan (wire.decoder-string! (&mut d) view 64)]
    [empty : wire.SshSpan (wire.decoder-string! (&mut d) view 64)]
    [opaque : wire.SshSpan (wire.decoder-string! (&mut d) view 64)]
    (begin
      (wire.decoder-finish! (&mut d))
      (test.assert-false d.failed "three strings")
      ;; RFC 4251 section 5: "testing" is 00 00 00 07 74 65 73 74 69 6e 67.
      (assert-text (wire.span-bytes view (& testing)) "testing" "string data")
      (test.assert-i64-eq empty.count 0 "empty string")
      (assert-bytes
        (wire.span-bytes view (& opaque))
        "00 ff 0a"
        "opaque bytes kept")
      (let
        [out : byte_buf.ByteBuf
          (wire.push-string
            (wire.push-string
              (wire.push-string
                (byte_buf.new)
                (wire.span-bytes view (& testing)))
              (wire.span-bytes view (& empty)))
            (wire.span-bytes view (& opaque)))]
        (test.assert-true
          (bytes-eq? (byte_buf.as-bytes (& out)) view)
          "strings re-encode byte for byte")))))

(define (decode-name-list [encoded : String] [limits : wire.SshWireLimits]) : wire.SshDecoder
  (let
    [buf : byte_buf.ByteBuf (hex encoded)]
    [view : (& buf bytes) (byte_buf.as-bytes (& buf))]
    [d : wire.SshDecoder (wire.decoder-new view)]
    [_list : wire.SshNameList
      (wire.decoder-name-list! (&mut d) view (& limits))]
    (begin
      (wire.decoder-finish! (&mut d))
      d)))

;; A name-list holding one name of `count` `a` bytes.
(define (name-of-length [count : i64]) : byte_buf.ByteBuf
  (let
    [out : byte_buf.ByteBuf (wire.push-uint32 (byte_buf.new) count)]
    (begin
      (while (< (byte_buf.len (& out)) (+ 4 count))
        (set! out (byte_buf.push out (cast 97 : u8))))
      out)))

(define (name-of-length-ok? [count : i64] [limits : wire.SshWireLimits]) : bool
  (let
    [encoded : byte_buf.ByteBuf (name-of-length count)]
    [view : (& encoded bytes) (byte_buf.as-bytes (& encoded))]
    [d : wire.SshDecoder (wire.decoder-new view)]
    [_names : wire.SshNameList
      (wire.decoder-name-list! (&mut d) view (& limits))]
    (begin
      (wire.decoder-finish! (&mut d))
      (not d.failed))))

(define (name-list-ok? [encoded : String]) : bool
  (let
    [d : wire.SshDecoder (decode-name-list encoded (wire.default-limits))]
    (not d.failed)))

(define (assert-name-list-error
  [encoded : String]
  [code : i64]
  [offset : i64]
  [message : String]) : unit
  (let
    [d : wire.SshDecoder (decode-name-list encoded (small-limits))]
    (begin
      (test.assert-true d.failed (clone message))
      (test.assert-i64-eq d.error.code code (clone message))
      (test.assert-i64-eq d.error.offset offset message))))

(define (assert-name-lists) : unit
  (let
    [limits : wire.SshWireLimits (wire.default-limits)]
    ;; RFC 4251 section 5: (), ("zlib") and ("zlib", "none").
    [buf : byte_buf.ByteBuf
      (hex
        "00 00 00 00 00 00 00 04 7a 6c 69 62 00 00 00 09 7a 6c 69 62 2c 6e 6f 6e 65")]
    [view : (& buf bytes) (byte_buf.as-bytes (& buf))]
    [d : wire.SshDecoder (wire.decoder-new view)]
    [none : wire.SshNameList (wire.decoder-name-list! (&mut d) view (& limits))]
    [one : wire.SshNameList (wire.decoder-name-list! (&mut d) view (& limits))]
    [two : wire.SshNameList (wire.decoder-name-list! (&mut d) view (& limits))]
    (begin
      (wire.decoder-finish! (&mut d))
      (test.assert-false d.failed "RFC name-lists decode")
      (test.assert-i64-eq (array-length none.names) 0 "empty list")
      (test.assert-i64-eq (array-length one.names) 1 "one name")
      (test.assert-i64-eq (array-length two.names) 2 "two names")
      (test.assert-true
        (wire.span-equals? view (& (array-ref one.names 0)) "zlib")
        "zlib")
      (test.assert-true
        (wire.span-equals? view (& (array-ref two.names 0)) "zlib")
        "first of two")
      (test.assert-true
        (wire.span-equals? view (& (array-ref two.names 1)) "none")
        "second of two")
      (let
        [names : (__tl_dyn-array String) (__tl_make-array String 2)]
        (begin
          (set! (array-ref names 0) "zlib")
          (set! (array-ref names 1) "none")
          (let
            [out : byte_buf.ByteBuf
              (wire.push-name-list (byte_buf.new) (& names))]
            (assert-bytes
              (byte_buf.as-bytes (& out))
              "00 00 00 09 7a 6c 69 62 2c 6e 6f 6e 65"
              "name-list encoder"))))
      ;; An extension name and a 64-byte name are valid.
      (test.assert-true
        (name-list-ok?
          "00 00 00 16 61 65 73 31 32 38 2d 67 63 6d 40 6f 70 65 6e 73 73 68 2e 63 6f 6d")
        "aes128-gcm@openssh.com")
      (test.assert-true
        (name-of-length-ok? 64 (wire.default-limits))
        "64-byte name")
      (let
        [long : byte_buf.ByteBuf (name-of-length 65)]
        [view : (& long bytes) (byte_buf.as-bytes (& long))]
        [d : wire.SshDecoder (wire.decoder-new view)]
        [_names : wire.SshNameList
          (wire.decoder-name-list! (&mut d) view (& limits))]
        (begin
          (test.assert-true d.failed "a 65-byte name")
          (test.assert-i64-eq d.error.code wire.error-name-list "is malformed")
          (test.assert-i64-eq d.error.offset 4 "at its start")))
      (let
        [long : byte_buf.ByteBuf (name-of-length 65)]
        [view : (& long bytes) (byte_buf.as-bytes (& long))]
        [small : wire.SshWireLimits (small-limits)]
        [d : wire.SshDecoder (wire.decoder-new view)]
        [_names : wire.SshNameList
          (wire.decoder-name-list! (&mut d) view (& small))]
        (begin
          (test.assert-true d.failed "a 65-byte list over a 64-byte limit")
          (test.assert-i64-eq
            d.error.code
            wire.error-length-range
            "length range")
          (test.assert-i64-eq d.error.offset 0 "at its prefix")))
      (assert-name-list-error
        "00 00 00 05 2c 7a 6c 69 62"
        wire.error-name-list
        4
        "leading comma")
      (assert-name-list-error
        "00 00 00 05 7a 6c 69 62 2c"
        wire.error-name-list
        9
        "trailing comma")
      (assert-name-list-error
        "00 00 00 06 61 2c 2c 62 63 64"
        wire.error-name-list
        6
        "doubled comma")
      (assert-name-list-error
        "00 00 00 01 2c"
        wire.error-name-list
        4
        "lone comma")
      (assert-name-list-error
        "00 00 00 03 61 20 62"
        wire.error-name-list
        5
        "space")
      (assert-name-list-error
        "00 00 00 02 61 01"
        wire.error-name-list
        5
        "control byte")
      (assert-name-list-error "00 00 00 02 61 7f" wire.error-name-list 5 "DEL")
      (assert-name-list-error
        "00 00 00 02 61 80"
        wire.error-name-list
        5
        "non-ASCII byte")
      (assert-name-list-error
        "00 00 00 09 61 2c 62 2c 63 2c 64 2c 65"
        wire.error-too-many-names
        12
        "a fifth name is over the small limit"))))

(define (decode-mpint [encoded : String]) : wire.SshDecoder
  (let
    [buf : byte_buf.ByteBuf (hex encoded)]
    [view : (& buf bytes) (byte_buf.as-bytes (& buf))]
    [d : wire.SshDecoder (wire.decoder-new view)]
    [_value : wire.SshMpint (wire.decoder-mpint-positive! (&mut d) view 64)]
    (begin
      (wire.decoder-finish! (&mut d))
      d)))

(define (assert-mpint-error [encoded : String] [code : i64] [message : String]) : unit
  (let
    [d : wire.SshDecoder (decode-mpint encoded)]
    (begin
      (test.assert-true d.failed (clone message))
      (test.assert-i64-eq d.error.code code message))))

(define (assert-mpints) : unit
  (let
    ;; RFC 4251 section 5: 9a378f9b2e332a7 and 80.
    [buf : byte_buf.ByteBuf
      (hex "00 00 00 08 09 a3 78 f9 b2 e3 32 a7 00 00 00 02 00 80")]
    [view : (& buf bytes) (byte_buf.as-bytes (& buf))]
    [d : wire.SshDecoder (wire.decoder-new view)]
    [first : wire.SshMpint (wire.decoder-mpint-positive! (&mut d) view 64)]
    [second : wire.SshMpint (wire.decoder-mpint-positive! (&mut d) view 64)]
    (begin
      (wire.decoder-finish! (&mut d))
      (test.assert-false d.failed "RFC positive mpints")
      (assert-bytes
        (wire.span-bytes view (& first.magnitude))
        "09 a3 78 f9 b2 e3 32 a7"
        "magnitude without a sign byte")
      (assert-bytes
        (wire.span-bytes view (& second.data))
        "00 80"
        "data keeps the sign byte")
      (assert-bytes
        (wire.span-bytes view (& second.magnitude))
        "80"
        "magnitude drops it")
      (let
        [magnitude : byte_buf.ByteBuf (hex "00 00 80")]
        [out : byte_buf.ByteBuf
          (wire.push-mpint-positive
            (wire.push-mpint-positive
              (byte_buf.new)
              (wire.span-bytes view (& first.magnitude)))
            (byte_buf.as-bytes (& magnitude)))]
        (test.assert-true
          (bytes-eq? (byte_buf.as-bytes (& out)) view)
          "mpint encoder drops leading zeros and adds the sign byte"))
      ;; RFC 4251 section 5: 0, -1234 and -deadbeef.
      (assert-mpint-error
        "00 00 00 00"
        wire.error-mpint-zero
        "zero is not positive")
      (assert-mpint-error "00 00 00 02 ed cc" wire.error-mpint-negative "-1234")
      (assert-mpint-error
        "00 00 00 05 ff 21 52 41 11"
        wire.error-mpint-negative
        "-deadbeef")
      (assert-mpint-error
        "00 00 00 02 00 7f"
        wire.error-mpint-noncanonical
        "needless zero byte")
      (assert-mpint-error
        "00 00 00 01 00"
        wire.error-mpint-noncanonical
        "zero with a sign byte")
      (assert-mpint-error
        "00 00 00 41 00"
        wire.error-length-range
        "an mpint over its limit fails before its data is read"))))

;; Every proper prefix of each vector fails as truncated, and only the whole
;; vector decodes.
(define (assert-truncation-at-every-split) : unit
  (let
    [vector : byte_buf.ByteBuf
      (hex
        "00 00 00 09 7a 6c 69 62 2c 6e 6f 6e 65 00 00 00 02 00 80 00 00 00 03 61 62 63 29 b7 f4 aa 01")]
    [full : i64 (byte_buf.len (& vector))]
    [limits : wire.SshWireLimits (wire.default-limits)]
    [cut : i64 0]
    (while (<= cut full)
      (let
        [view : (& vector bytes)
          (byte_buf.bytes-slice-view (byte_buf.as-bytes (& vector)) 0 cut)]
        [d : wire.SshDecoder (wire.decoder-new view)]
        [_names : wire.SshNameList
          (wire.decoder-name-list! (&mut d) view (& limits))]
        [_mpint : wire.SshMpint (wire.decoder-mpint-positive! (&mut d) view 64)]
        [_text : wire.SshSpan (wire.decoder-string! (&mut d) view 64)]
        [_number : i64 (wire.decoder-uint32! (&mut d) view)]
        [_flag : bool (wire.decoder-boolean! (&mut d) view)]
        (begin
          (wire.decoder-finish! (&mut d))
          (if (= cut full)
            (test.assert-false d.failed "the whole vector decodes")
            (begin
              (test.assert-true d.failed "a prefix fails")
              (test.assert-i64-eq
                d.error.code
                wire.error-truncated
                "as truncated")))
          (set! cut (+ cut 1)))))))

;; A nested public-key blob read through a subcursor must be consumed exactly;
;; its fields keep their bytes.
(define (assert-nested-blob) : unit
  (let
    [buf : byte_buf.ByteBuf
      (hex
        "00 00 00 1b 00 00 00 0b 73 73 68 2d 65 64 32 35 35 31 39 00 00 00 08 01 02 03 04 05 06 07 08 00 00 00 01 ff")]
    [view : (& buf bytes) (byte_buf.as-bytes (& buf))]
    [outer : wire.SshDecoder (wire.decoder-new view)]
    [blob : wire.SshSpan (wire.decoder-string! (&mut outer) view 1024)]
    [trailer : wire.SshSpan (wire.decoder-string! (&mut outer) view 1024)]
    [inner : wire.SshDecoder (wire.decoder-sub (& blob))]
    [format : wire.SshSpan (wire.decoder-string! (&mut inner) view 64)]
    [key : wire.SshSpan (wire.decoder-string! (&mut inner) view 64)]
    (begin
      (wire.decoder-finish! (&mut outer))
      (wire.decoder-finish! (&mut inner))
      (test.assert-false outer.failed "outer view")
      (test.assert-false inner.failed "blob consumed exactly")
      (test.assert-true
        (wire.span-equals? view (& format) "ssh-ed25519")
        "key format")
      (assert-bytes
        (wire.span-bytes view (& key))
        "01 02 03 04 05 06 07 08"
        "key bytes")
      (assert-bytes
        (wire.span-bytes view (& trailer))
        "ff"
        "outer field after the blob")
      ;; The same blob with one byte too many inside fails at that byte.
      (let
        [long-buf : byte_buf.ByteBuf
          (hex
            "00 00 00 1c 00 00 00 0b 73 73 68 2d 65 64 32 35 35 31 39 00 00 00 08 01 02 03 04 05 06 07 08 00")]
        [long-view : (& long-buf bytes) (byte_buf.as-bytes (& long-buf))]
        [long-outer : wire.SshDecoder (wire.decoder-new long-view)]
        [long-blob : wire.SshSpan
          (wire.decoder-string! (&mut long-outer) long-view 1024)]
        [long-inner : wire.SshDecoder (wire.decoder-sub (& long-blob))]
        [_format : wire.SshSpan
          (wire.decoder-string! (&mut long-inner) long-view 64)]
        [_key : wire.SshSpan
          (wire.decoder-string! (&mut long-inner) long-view 64)]
        (begin
          (wire.decoder-finish! (&mut long-inner))
          (test.assert-true long-inner.failed "trailing byte inside a blob")
          (test.assert-i64-eq
            long-inner.error.code
            wire.error-trailing
            "as trailing")
          (test.assert-i64-eq long-inner.error.offset 31 "at the extra byte"))))))

(define (assert-length-limits) : unit
  (let
    [buf : byte_buf.ByteBuf (hex "00 00 00 21 00")]
    [view : (& buf bytes) (byte_buf.as-bytes (& buf))]
    [d : wire.SshDecoder (wire.decoder-new view)]
    [_span : wire.SshSpan (wire.decoder-string! (&mut d) view 32)]
    (begin
      (test.assert-true d.failed "33-byte string over a 32-byte limit")
      (test.assert-i64-eq d.error.code wire.error-length-range "length range")
      (test.assert-i64-eq d.error.offset 0 "at the prefix")
      (let
        [huge-buf : byte_buf.ByteBuf (hex "ff ff ff ff 00 00")]
        [huge-view : (& huge-buf bytes) (byte_buf.as-bytes (& huge-buf))]
        [huge : wire.SshDecoder (wire.decoder-new huge-view)]
        [_huge-span : wire.SshSpan
          (wire.decoder-string! (&mut huge) huge-view 262144)]
        (begin
          (test.assert-true
            huge.failed
            "a 4 GiB length is refused before any copy")
          (test.assert-i64-eq
            huge.error.code
            wire.error-length-range
            "huge length range"))))))

;; --- identification --------------------------------------------------------------
;; Feed `stream` in pieces of at most `chunk` bytes and record each step: B and
;; the line for a banner line, I and the line for the identification, F and
;; the error code and offset for a failure, and the bytes left unconsumed.
(define (ident-transcript
  [stream : (& stream bytes)]
  [chunk : i64]
  [accept-banner : bool]
  [limits : wire.SshWireLimits]) : byte_buf.ByteBuf
  (let
    [reader : wire.SshIdentReader (wire.ident-reader-new limits accept-banner)]
    [out : byte_buf.ByteBuf (byte_buf.new)]
    [count : i64 (byte_buf.bytes-length stream)]
    [pos : i64 0]
    [stop : bool false]
    [failed : bool false]
    (begin
      (while (and (not stop) (< pos count))
        (let
          [piece-end : i64
            (if (< (+ pos chunk) count)
              (+ pos chunk)
              count)]
          (while (and (not stop) (< pos piece-end))
            (match (wire.ident-reader-next!
              (&mut reader)
              (byte_buf.bytes-slice-view stream pos (- piece-end pos)))
              [(wire.SshIdentNeedMore consumed) (set! pos (+ pos consumed))]
              [(wire.SshIdentBanner consumed)
                (begin
                  (set! pos (+ pos consumed))
                  (set! out (byte_buf.push out (cast 66 : u8)))
                  (set!
                    out
                    (wire.push-string out (wire.ident-reader-line (& reader)))))]
              [(wire.SshIdentComplete consumed)
                (begin
                  (set! pos (+ pos consumed))
                  (set! out (byte_buf.push out (cast 73 : u8)))
                  (set!
                    out
                    (wire.push-string out (wire.ident-reader-line (& reader))))
                  (set! stop true))]
              [(wire.SshIdentFailed error)
                (begin
                  (set! out (byte_buf.push out (cast 70 : u8)))
                  (set! out (wire.push-uint32 out error.code))
                  (set! out (wire.push-uint32 out error.offset))
                  (set! failed true)
                  (set! stop true))]))))
      ;; After a failure the stream is dead, so no remainder is recorded.
      (if failed
        out
        (wire.push-uint32 out (- count pos))))))

(define (assert-ident-splits
  [stream : (& stream bytes)]
  [accept-banner : bool]
  [message : String]) : unit
  (let
    [whole : byte_buf.ByteBuf
      (ident-transcript stream 100000 accept-banner (wire.default-limits))]
    [chunk : i64 1]
    (while (<= chunk (byte_buf.bytes-length stream))
      (let
        [split : byte_buf.ByteBuf
          (ident-transcript stream chunk accept-banner (wire.default-limits))]
        (begin
          (test.assert-true
            (bytes-eq?
              (byte_buf.as-bytes (& split))
              (byte_buf.as-bytes (& whole)))
            (clone message))
          (set! chunk (+ chunk 1)))))))

(define (ident-error-code [text : String] [accept-banner : bool]) : i64
  (ident-error-code-bytes (byte_buf.str-as-bytes (& text)) accept-banner))

(define (ident-error-code-bytes
  [stream : (& stream bytes)]
  [accept-banner : bool]) : i64
  (let
    [reader : wire.SshIdentReader
      (wire.ident-reader-new (wire.default-limits) accept-banner)]
    [pos : i64 0]
    [code : i64 0]
    [done : bool false]
    (begin
      (while (and (not done) (< pos (byte_buf.bytes-length stream)))
        (match (wire.ident-reader-next!
          (&mut reader)
          (byte_buf.bytes-slice-view
            stream
            pos
            (- (byte_buf.bytes-length stream) pos)))
          [(wire.SshIdentNeedMore consumed) (set! pos (+ pos consumed))]
          [(wire.SshIdentBanner consumed) (set! pos (+ pos consumed))]
          [(wire.SshIdentComplete _) (set! done true)]
          [(wire.SshIdentFailed error)
            (begin
              (set! code error.code)
              (set! done true))]))
      code)))

(define (assert-identification) : unit
  (let
    [line : String "SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.5\r\n"]
    [stream : (& line bytes) (byte_buf.str-as-bytes (& line))]
    [reader : wire.SshIdentReader
      (wire.ident-reader-new (wire.default-limits) false)]
    (begin
      (match (wire.ident-reader-next! (&mut reader) stream)
        [(wire.SshIdentComplete consumed)
          (test.assert-i64-eq
            consumed
            (byte_buf.bytes-length stream)
            "whole line taken")]
        [_ (test.assert-true false "OpenSSH identification completes")])
      (let
        [text : (& reader bytes) (wire.ident-reader-line (& reader))]
        [fields : wire.SshIdentification
          (wire.ident-reader-identification (& reader))]
        (begin
          (assert-text
            text
            "SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.5"
            "the exchange-hash view drops only CR LF")
          (test.assert-true
            (wire.span-equals? text (& fields.protoversion) "2.0")
            "2.0")
          (test.assert-true
            (wire.span-equals? text (& fields.software) "OpenSSH_9.6p1")
            "software version")
          (test.assert-true fields.has-comments "has comments")
          (test.assert-true
            (wire.span-equals? text (& fields.comments) "Ubuntu-3ubuntu13.5")
            "comments may contain a dash")))
      ;; A complete reader takes nothing more.
      (match (wire.ident-reader-next! (&mut reader) stream)
        [(wire.SshIdentComplete consumed)
          (test.assert-i64-eq consumed 0 "nothing after completion")]
        [_ (test.assert-true false "still complete")])
      ;; Banner lines, then the identification, then the first packet's bytes,
      ;; which stay unconsumed.
      (let
        [packet-start : byte_buf.ByteBuf (hex "00 00 00 0c")]
        [server : byte_buf.ByteBuf
          (byte_buf.append-bytes
            (byte_buf.from-string
              "Welcome to the host\r\nsecond line\nSSH-1.99-Server_1\r\n")
            (byte_buf.as-bytes (& packet-start)))]
        [transcript : byte_buf.ByteBuf
          (ident-transcript
            (byte_buf.as-bytes (& server))
            100000
            true
            (wire.default-limits))]
        [welcome : String "Welcome to the host"]
        [second : String "second line"]
        [server-id : String "SSH-1.99-Server_1"]
        [expected : byte_buf.ByteBuf
          (wire.push-uint32
            (wire.push-string
              (byte_buf.push
                (wire.push-string
                  (byte_buf.push
                    (wire.push-string
                      (byte_buf.push (byte_buf.new) (cast 66 : u8))
                      (byte_buf.str-as-bytes (& welcome)))
                    (cast 66 : u8))
                  (byte_buf.str-as-bytes (& second)))
                (cast 73 : u8))
              (byte_buf.str-as-bytes (& server-id)))
            4)]
        (begin
          (test.assert-true
            (bytes-eq?
              (byte_buf.as-bytes (& transcript))
              (byte_buf.as-bytes (& expected)))
            "banner lines, 1.99, and the packet bytes left over")
          (assert-ident-splits
            (byte_buf.as-bytes (& server))
            true
            "server stream at every chunk size")))
      (assert-ident-splits stream false "client line at every chunk size")
      (test.assert-i64-eq
        (ident-error-code "hello\r\nSSH-2.0-x\r\n" false)
        wire.error-identification
        "a client must send its identification first")
      (test.assert-i64-eq
        (ident-error-code "SSH-1.5-old\r\n" false)
        wire.error-protocol-version
        "SSH-1.5")
      (test.assert-i64-eq
        (ident-error-code "SSH-2.0-\r\n" false)
        wire.error-identification
        "empty software version")
      (test.assert-i64-eq
        (ident-error-code "SSH-2.0-a-b\r\n" false)
        wire.error-identification
        "dash in the software version")
      (test.assert-i64-eq
        (ident-error-code "SSH-2.0-x\n" false)
        wire.error-identification
        "LF without CR")
      (let
        [nul-tail : String "b\r\n"]
        [nul : byte_buf.ByteBuf
          (byte_buf.append-bytes
            (byte_buf.push (byte_buf.from-string "SSH-2.0-x a") (cast 0 : u8))
            (byte_buf.str-as-bytes (& nul-tail)))]
        (test.assert-i64-eq
          (ident-error-code-bytes (byte_buf.as-bytes (& nul)) false)
          wire.error-identification
          "NUL in the comments"))
      (test.assert-i64-eq
        (ident-error-code "SSH-2.0x\r\n" false)
        wire.error-identification
        "no dash after the version")
      (let
        [buf : byte_buf.ByteBuf (byte_buf.from-string "SSH-2.0-")]
        (begin
          (while (< (byte_buf.len (& buf)) 253)
            (set! buf (byte_buf.push buf (cast 97 : u8))))
          (let
            [exact : byte_buf.ByteBuf
              (byte_buf.push
                (byte_buf.push (clone buf) (cast 13 : u8))
                (cast 10 : u8))]
            [exact-text : String (byte_buf.to-string exact)]
            (test.assert-i64-eq
              (ident-error-code exact-text false)
              0
              "a 255-byte identification line is accepted"))
          (let
            [over : byte_buf.ByteBuf
              (byte_buf.push
                (byte_buf.push
                  (byte_buf.push buf (cast 97 : u8))
                  (cast 13 : u8))
                (cast 10 : u8))]
            [over-text : String (byte_buf.to-string over)]
            (test.assert-i64-eq
              (ident-error-code over-text false)
              wire.error-line-too-long
              "a 256-byte identification line is refused")))))))

(define (assert-banner-limits) : unit
  (let
    [limits : wire.SshWireLimits (small-limits)]
    [lines : String "a\r\nb\r\nc\r\nd\r\ne\r\nSSH-2.0-x\r\n"]
    [transcript : byte_buf.ByteBuf
      (ident-transcript (byte_buf.str-as-bytes (& lines)) 100000 true limits)]
    [view : (& transcript bytes) (byte_buf.as-bytes (& transcript))]
    [count : i64 (byte_buf.bytes-length view)]
    (begin
      ;; Four banner lines pass the small limit; the fifth fails at offset 12.
      (test.assert-i64-eq
        (cast (byte_buf.bytes-ref view (- count 9)) : i64)
        70
        "fifth banner line fails")
      (test.assert-i64-eq
        (wire.read-be view (- count 8) 4)
        wire.error-banner-limit
        "banner line limit")
      (test.assert-i64-eq
        (wire.read-be view (- count 4) 4)
        12
        "at the fifth line")
      (let
        [long : String
          "0123456789012345678901234567890123456789012345678901234567890123456789\r\n"]
        [long-transcript : byte_buf.ByteBuf
          (ident-transcript (byte_buf.str-as-bytes (& long)) 100000 true limits)]
        [long-view : (& long-transcript bytes)
          (byte_buf.as-bytes (& long-transcript))]
        (test.assert-i64-eq
          (wire.read-be long-view 1 4)
          wire.error-line-too-long
          "a banner line over its limit fails before its end")))))

(define (assert-identification-encoder) : unit
  (let
    [plain : byte_buf.ByteBuf
      (wire.encode-identification (byte_buf.new) "TypeLisp_0.1" "")]
    [commented : byte_buf.ByteBuf
      (wire.encode-identification (byte_buf.new) "TypeLisp_0.1" "build 7")]
    (begin
      (assert-text
        (byte_buf.as-bytes (& plain))
        "SSH-2.0-TypeLisp_0.1\r\n"
        "no comments")
      (assert-text
        (byte_buf.as-bytes (& commented))
        "SSH-2.0-TypeLisp_0.1 build 7\r\n"
        "with comments"))))

;; --- framing --------------------------------------------------------------------------
(define (assert-plans) : unit
  (let
    [limits : wire.SshWireLimits (wire.default-limits)]
    [small : wire.SshWireLimits (small-limits)]
    [clear : wire.SshFrameMode (wire.SshFrameClear)]
    [gcm : wire.SshFrameMode (wire.SshFrameAesGcm)]
    [payload : i64 1]
    (begin
      (while (<= payload 600)
        (begin
          (match (wire.frame-plan (& clear) payload (& limits))
            [(wire.SshFramePlanOk plan)
              (begin
                (test.assert-i64-eq
                  plan.packet-length
                  (+ (+ 1 payload) plan.padding-length)
                  "clear packet length")
                (test.assert-true
                  (>= plan.padding-length 4)
                  "clear padding at least 4")
                (test.assert-true
                  (< plan.padding-length 12)
                  "clear padding minimal")
                (test.assert-i64-eq
                  (% (+ 4 plan.packet-length) 8)
                  0
                  "clear alignment")
                (test.assert-true
                  (>= (+ 4 plan.packet-length) 16)
                  "clear minimum size"))]
            [(wire.SshFramePlanErr _) (test.assert-true false "clear plan")])
          (match (wire.frame-plan (& gcm) payload (& limits))
            [(wire.SshFramePlanOk plan)
              (begin
                (test.assert-i64-eq
                  plan.packet-length
                  (+ (+ 1 payload) plan.padding-length)
                  "gcm packet length")
                (test.assert-true
                  (>= plan.padding-length 4)
                  "gcm padding at least 4")
                (test.assert-true
                  (< plan.padding-length 20)
                  "gcm padding minimal")
                (test.assert-i64-eq (% plan.packet-length 16) 0 "gcm alignment"))]
            [(wire.SshFramePlanErr _) (test.assert-true false "gcm plan")])
          (set! payload (+ payload 1))))
      (match (wire.frame-plan (& clear) 0 (& limits))
        [(wire.SshFramePlanErr error)
          (test.assert-i64-eq
            error.code
            wire.error-empty-payload
            "empty payload")]
        [_ (test.assert-true false "an empty payload has no plan")])
      (match (wire.frame-plan (& clear) 4090 (& small))
        [(wire.SshFramePlanErr error)
          (test.assert-i64-eq
            error.code
            wire.error-packet-length
            "over the packet limit")]
        [_ (test.assert-true false "a packet over the limit has no plan")]))))

;; A clear packet carrying `payload` with padding bytes 0x50, 0x51, ...
(define (clear-packet [payload : (& payload bytes)]) : byte_buf.ByteBuf
  (let
    [limits : wire.SshWireLimits (wire.default-limits)]
    [mode : wire.SshFrameMode (wire.SshFrameClear)]
    (match (wire.frame-plan (& mode) (byte_buf.bytes-length payload) (& limits))
      [(wire.SshFramePlanErr _) (byte_buf.new)]
      [(wire.SshFramePlanOk plan)
        (let
          [padding : byte_buf.ByteBuf (byte_buf.new)]
          (begin
            (while (< (byte_buf.len (& padding)) plan.padding-length)
              (let
                [next : i64 (+ 80 (byte_buf.len (& padding)))]
                (set! padding (byte_buf.push padding (cast next : u8)))))
            (match (wire.encode-frame
              (& mode)
              payload
              (byte_buf.as-bytes (& padding))
              (& limits))
              [(wire.SshFrameOk packet) packet]
              [(wire.SshFrameErr _) (byte_buf.new)])))])))

;; Feed `stream` to a clear packet reader in pieces of at most `chunk` bytes
;; and record each packet's sequence number, payload and padding, any failure,
;; and the bytes left unconsumed.
(define (packet-transcript
  [stream : (& stream bytes)]
  [chunk : i64]
  [limits : wire.SshWireLimits]) : byte_buf.ByteBuf
  (let
    [reader : wire.SshPacketReader
      (wire.packet-reader-new limits (wire.SshFrameClear))]
    [out : byte_buf.ByteBuf (byte_buf.new)]
    [count : i64 (byte_buf.bytes-length stream)]
    [pos : i64 0]
    [stop : bool false]
    (begin
      (while (and (not stop) (< pos count))
        (let
          [piece-end : i64
            (if (< (+ pos chunk) count)
              (+ pos chunk)
              count)]
          (while (and (not stop) (< pos piece-end))
            (match (wire.packet-reader-next!
              (&mut reader)
              (byte_buf.bytes-slice-view stream pos (- piece-end pos)))
              [(wire.SshPacketNeedMore consumed) (set! pos (+ pos consumed))]
              [(wire.SshPacketComplete consumed)
                (begin
                  (set! pos (+ pos consumed))
                  (set!
                    out
                    (wire.push-uint32
                      out
                      (wire.packet-reader-sequence (& reader))))
                  (set!
                    out
                    (wire.push-string
                      out
                      (wire.packet-reader-payload (& reader))))
                  (set!
                    out
                    (wire.push-string
                      out
                      (wire.packet-reader-padding (& reader)))))]
              [(wire.SshPacketFailed error)
                (begin
                  (set! out (byte_buf.push out (cast 70 : u8)))
                  (set! out (wire.push-uint32 out error.code))
                  (set! out (wire.push-uint32 out error.offset))
                  (set! stop true))]))))
      ;; After a failure the stream is dead: how much of the failing header
      ;; earlier pieces buffered depends on the split, so it is not recorded.
      (if stop
        out
        (wire.push-uint32 out (- count pos))))))

(define (assert-transcripts-agree
  [stream : (& stream bytes)]
  [message : String]) : unit
  (let
    [whole : byte_buf.ByteBuf
      (packet-transcript stream 1000000 (wire.default-limits))]
    [chunk : i64 1]
    (while (<= chunk (+ 1 (byte_buf.bytes-length stream)))
      (let
        [split : byte_buf.ByteBuf
          (packet-transcript stream chunk (wire.default-limits))]
        (begin
          (test.assert-true
            (bytes-eq?
              (byte_buf.as-bytes (& split))
              (byte_buf.as-bytes (& whole)))
            (clone message))
          (set! chunk (+ chunk 1)))))))

(define (assert-clear-packets) : unit
  (let
    [first-payload : byte_buf.ByteBuf (hex "15")]
    [second-payload : byte_buf.ByteBuf
      (hex "05 00 00 00 0c 73 73 68 2d 75 73 65 72 61 75 74 68")]
    [partial-header : byte_buf.ByteBuf (hex "00 00 00")]
    [first : byte_buf.ByteBuf
      (clear-packet (byte_buf.as-bytes (& first-payload)))]
    [second : byte_buf.ByteBuf
      (clear-packet (byte_buf.as-bytes (& second-payload)))]
    [stream : byte_buf.ByteBuf
      (byte_buf.append-bytes
        (byte_buf.append-bytes
          (byte_buf.append-bytes (byte_buf.new) (byte_buf.as-bytes (& first)))
          (byte_buf.as-bytes (& second)))
        (byte_buf.as-bytes (& partial-header)))]
    [transcript : byte_buf.ByteBuf
      (packet-transcript
        (byte_buf.as-bytes (& stream))
        1000000
        (wire.default-limits))]
    (begin
      ;; SSH_MSG_NEWKEYS: packet_length 12, padding 10 -- the 16-byte minimum.
      (assert-bytes
        (byte_buf.as-bytes (& first))
        "00 00 00 0c 0a 15 50 51 52 53 54 55 56 57 58 59"
        "NEWKEYS frame with the caller's padding")
      (assert-bytes
        (byte_buf.as-bytes (& transcript))
        "00 00 00 00 00 00 00 01 15 00 00 00 0a 50 51 52 53 54 55 56 57 58 59 00 00 00 01 00 00 00 11 05 00 00 00 0c 73 73 68 2d 75 73 65 72 61 75 74 68 00 00 00 0a 50 51 52 53 54 55 56 57 58 59 00 00 00 00"
        "two packets, sequence numbers and padding; the partial third header is buffered")
      (assert-transcripts-agree
        (byte_buf.as-bytes (& stream))
        "packets at every chunk size"))))

(define (packet-error [encoded : String] [limits : wire.SshWireLimits]) : byte_buf.ByteBuf
  (let
    [stream : byte_buf.ByteBuf (hex encoded)]
    (packet-transcript (byte_buf.as-bytes (& stream)) 1000000 limits)))

(define (assert-packet-error
  [encoded : String]
  [code : i64]
  [offset : i64]
  [message : String]) : unit
  (let
    [transcript : byte_buf.ByteBuf (packet-error encoded (wire.default-limits))]
    [view : (& transcript bytes) (byte_buf.as-bytes (& transcript))]
    (begin
      (test.assert-i64-eq
        (cast (byte_buf.bytes-ref view 0) : i64)
        70
        (clone message))
      (test.assert-i64-eq (wire.read-be view 1 4) code (clone message))
      (test.assert-i64-eq (wire.read-be view 5 4) offset message))))

(define (assert-malformed-packets) : unit
  (begin
    (assert-packet-error
      "00 00 00 04"
      wire.error-packet-length
      0
      "below the minimum size")
    (assert-packet-error
      "00 00 00 0d"
      wire.error-packet-alignment
      0
      "misaligned clear length")
    (assert-packet-error
      "00 04 00 04"
      wire.error-packet-length
      0
      "over the default packet limit, before any body byte")
    (assert-packet-error
      "00 00 00 0c 03 15 50 51 52 53 54 55 56 57 58 59"
      wire.error-padding-length
      4
      "padding below 4")
    (assert-packet-error
      "00 00 00 0c 0b 15 50 51 52 53 54 55 56 57 58 59"
      wire.error-empty-payload
      4
      "padding leaves no payload")
    (assert-packet-error
      "00 00 00 0c ff 15 50 51 52 53 54 55 56 57 58 59"
      wire.error-padding-length
      4
      "padding longer than the packet")
    ;; The failure is sticky: a valid packet after it is not read.
    (let
      [transcript : byte_buf.ByteBuf
        (packet-error
          "00 00 00 0d 00 00 00 0c 0a 15 50 51 52 53 54 55 56 57 58 59"
          (wire.default-limits))]
      (test.assert-i64-eq
        (byte_buf.len (& transcript))
        9
        "one failure record; the valid packet after it is never read"))))

(define (assert-sealed-packets) : unit
  (let
    [limits : wire.SshWireLimits (wire.default-limits)]
    [gcm : wire.SshFrameMode (wire.SshFrameAesGcm)]
    [payload : byte_buf.ByteBuf
      (hex "05 00 00 00 0c 73 73 68 2d 75 73 65 72 61 75 74 68")]
    [plan-padding : i64
      (match (wire.frame-plan (& gcm) (byte_buf.len (& payload)) (& limits))
        [(wire.SshFramePlanOk plan) plan.padding-length]
        [(wire.SshFramePlanErr _) 0])]
    [padding : byte_buf.ByteBuf (byte_buf.new)]
    [short-padding : byte_buf.ByteBuf (hex "a0 a0 a0")]
    [tag : byte_buf.ByteBuf
      (hex "f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 fa fb fc fd fe ff")]
    (begin
      (while (< (byte_buf.len (& padding)) plan-padding)
        (set! padding (byte_buf.push padding (cast 160 : u8))))
      (match (wire.encode-frame
        (& gcm)
        (byte_buf.as-bytes (& payload))
        (byte_buf.as-bytes (& short-padding))
        (& limits))
        [(wire.SshFrameErr error)
          (test.assert-i64-eq
            error.code
            wire.error-padding-mismatch
            "padding of the wrong size")]
        [(wire.SshFrameOk _)
          (test.assert-true false "wrong padding is refused")])
      (match (wire.encode-frame
        (& gcm)
        (byte_buf.as-bytes (& payload))
        (byte_buf.as-bytes (& padding))
        (& limits))
        [(wire.SshFrameErr _) (test.assert-true false "gcm frame")]
        [(wire.SshFrameOk frame)
          (let
            ;; A stand-in for the transform: the body is sent as is, with a
            ;; 16-byte tag after it.
            [stream : byte_buf.ByteBuf
              (byte_buf.append-bytes
                (byte_buf.append-bytes
                  (byte_buf.new)
                  (byte_buf.as-bytes (& frame)))
                (byte_buf.as-bytes (& tag)))]
            [reader : wire.SshPacketReader
              (wire.packet-reader-new limits (wire.SshFrameAesGcm))]
            (begin
              (test.assert-i64-eq
                (% (- (byte_buf.len (& frame)) 4) 16)
                0
                "gcm body aligned")
              (match (wire.packet-reader-next!
                (&mut reader)
                (byte_buf.as-bytes (& stream)))
                [(wire.SshPacketComplete consumed)
                  (test.assert-i64-eq
                    consumed
                    (byte_buf.len (& stream))
                    "whole sealed packet")]
                [_ (test.assert-true false "sealed packet completes")])
              (test.assert-true
                (bytes-eq?
                  (wire.packet-reader-header (& reader))
                  (byte_buf.bytes-slice-view (byte_buf.as-bytes (& frame)) 0 4))
                "associated data is the length field")
              (assert-bytes
                (wire.packet-reader-tag (& reader))
                "f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 fa fb fc fd fe ff"
                "tag boundary")
              (test.assert-i64-eq
                (byte_buf.bytes-length (wire.packet-reader-payload (& reader)))
                0
                "no payload before the transform opens the body")
              (match (wire.open-plain-body
                (wire.packet-reader-body (& reader))
                4)
                [(wire.SshBodyErr _)
                  (test.assert-true false "authenticated body opens")]
                [(wire.SshBodyOk body)
                  (begin
                    (test.assert-true
                      (bytes-eq?
                        (wire.span-bytes
                          (wire.packet-reader-body (& reader))
                          (& body.payload))
                        (byte_buf.as-bytes (& payload)))
                      "payload from the opened body")
                    (test.assert-i64-eq
                      body.padding.count
                      plan-padding
                      "padding span"))])))]))))

(define (assert-sequence-wrap) : unit
  (let
    [reader : wire.SshPacketReader
      (wire.packet-reader-new (wire.default-limits) (wire.SshFrameClear))]
    [payload : byte_buf.ByteBuf (hex "15")]
    [packet : byte_buf.ByteBuf (clear-packet (byte_buf.as-bytes (& payload)))]
    (begin
      (set! reader.sequence wire.max-uint32)
      (match (wire.packet-reader-next!
        (&mut reader)
        (byte_buf.as-bytes (& packet)))
        [(wire.SshPacketComplete _)
          (test.assert-i64-eq
            (wire.packet-reader-sequence (& reader))
            wire.max-uint32
            "last sequence")]
        [_ (test.assert-true false "packet at the last sequence number")])
      (match (wire.packet-reader-next!
        (&mut reader)
        (byte_buf.as-bytes (& packet)))
        [(wire.SshPacketComplete _)
          (test.assert-i64-eq
            (wire.packet-reader-sequence (& reader))
            0
            "wraps to zero")]
        [_ (test.assert-true false "packet after the wrap")])
      (wire.packet-reader-set-mode! (&mut reader) (wire.SshFrameAesGcm))
      (test.assert-i64-eq
        (wire.mode-tag-length (& reader.mode))
        16
        "mode switches between packets"))))

;; --- fuzz gates --------------------------------------------------------------------------
;; Whether the names of `names`, read from `view`, re-encode to exactly the
;; first `consumed` bytes of `view`.
(define (name-list-reencodes?
  [view : (& view bytes)]
  [names : (& names wire.SshNameList)]
  [consumed : i64]) : bool
  (let
    [count : i64 (array-length names.names)]
    [strings : (__tl_dyn-array String) (__tl_make-array String count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [span : wire.SshSpan
            (wire.copy-span (& (array-ref names.names index)))]
          (begin
            (set!
              (array-ref strings index)
              (byte_buf.bytes-to-string (wire.span-bytes view (& span))))
            (set! index (+ index 1)))))
      (let
        [again : byte_buf.ByteBuf
          (wire.push-name-list (byte_buf.new) (& strings))]
        (bytes-eq?
          (byte_buf.as-bytes (& again))
          (byte_buf.bytes-slice-view view 0 consumed))))))

;; Random byte strings decode or fail without reading past their end, and
;; whatever decodes re-encodes to exactly the bytes it was read from.
(define (assert-decode-encode-idempotence) : unit
  (let
    [state : i64 7229]
    [round : i64 0]
    [limits : wire.SshWireLimits (small-limits)]
    (while (< round 3000)
      (let
        [length : i64 0]
        [buf : byte_buf.ByteBuf (byte_buf.new)]
        (begin
          (set! state (lcg state))
          (set! length (% state 24))
          ;; Mostly short length prefixes and name bytes, so many inputs
          ;; decode.
          (set! state (lcg state))
          (set! buf (wire.push-uint32 buf (% state 20)))
          (while (< (byte_buf.len (& buf)) (+ 4 length))
            (let
              [next : i64 (lcg state)]
              [code : i64
                (if (= (% next 7) 0)
                  44
                  (if (= (% next 11) 0)
                    (% (/ next 16) 256)
                    (+ 97 (% (/ next 16) 26))))]
              (begin
                (set! state next)
                (set! buf (byte_buf.push buf (cast code : u8))))))
          (let
            [view : (& buf bytes) (byte_buf.as-bytes (& buf))]
            [d : wire.SshDecoder (wire.decoder-new view)]
            [names : wire.SshNameList
              (wire.decoder-name-list! (&mut d) view (& limits))]
            (begin
              (test.assert-true
                (<= d.pos (byte_buf.bytes-length view))
                "name-list stays in view")
              (when
                (not d.failed)
                (test.assert-true
                  (name-list-reencodes? view (& names) d.pos)
                  "name-list re-encodes exactly"))))
          (let
            [view : (& buf bytes) (byte_buf.as-bytes (& buf))]
            [d : wire.SshDecoder (wire.decoder-new view)]
            [value : wire.SshMpint
              (wire.decoder-mpint-positive! (&mut d) view 16)]
            (begin
              (test.assert-true
                (<= d.pos (byte_buf.bytes-length view))
                "mpint stays in view")
              (when
                (not d.failed)
                (let
                  [again : byte_buf.ByteBuf
                    (wire.push-mpint-positive
                      (byte_buf.new)
                      (wire.span-bytes view (& value.magnitude)))]
                  (test.assert-true
                    (bytes-eq?
                      (byte_buf.as-bytes (& again))
                      (byte_buf.bytes-slice-view view 0 d.pos))
                    "mpint re-encodes exactly")))))
          (set! round (+ round 1)))))))

;; Random packet streams, valid and corrupted, give the same transcript fed
;; whole or in random pieces.
(define (assert-fragmentation-independence) : unit
  (let
    [state : i64 4253]
    [round : i64 0]
    (while (< round 60)
      (let
        [stream : byte_buf.ByteBuf (byte_buf.new)]
        [packets : i64 0]
        (begin
          (set! state (lcg state))
          (set! packets (+ 1 (% state 4)))
          (while (> packets 0)
            (let
              [payload : byte_buf.ByteBuf (byte_buf.new)]
              [length : i64 0]
              (begin
                (set! state (lcg state))
                (set! length (+ 1 (% state 70)))
                (while (< (byte_buf.len (& payload)) length)
                  (begin
                    (set! state (lcg state))
                    (set!
                      payload
                      (byte_buf.push payload (cast (% state 256) : u8)))))
                (let
                  [packet : byte_buf.ByteBuf
                    (clear-packet (byte_buf.as-bytes (& payload)))]
                  (set!
                    stream
                    (byte_buf.append-bytes
                      stream
                      (byte_buf.as-bytes (& packet)))))
                (set! packets (- packets 1)))))
          ;; Every third stream has one byte flipped.
          (when
            (= (% round 3) 0)
            (begin
              (set! state (lcg state))
              (let
                [at : i64 (% state (byte_buf.len (& stream)))]
                [flipped : i64
                  (bit-xor (cast (byte_buf.ref (& stream) at) : i64) 255)]
                (set! stream (byte_buf.set! stream at (cast flipped : u8))))))
          (let
            [whole : byte_buf.ByteBuf
              (packet-transcript
                (byte_buf.as-bytes (& stream))
                1000000
                (wire.default-limits))]
            [piece : i64 0]
            (begin
              (set! state (lcg state))
              (set! piece (+ 1 (% state 9)))
              (let
                [split : byte_buf.ByteBuf
                  (packet-transcript
                    (byte_buf.as-bytes (& stream))
                    piece
                    (wire.default-limits))]
                (test.assert-true
                  (bytes-eq?
                    (byte_buf.as-bytes (& split))
                    (byte_buf.as-bytes (& whole)))
                  "random streams agree across fragmentation"))))
          (set! round (+ round 1)))))))

(define (main) : i64
  (begin
    (assert-fixed-width)
    (assert-strings)
    (assert-name-lists)
    (assert-mpints)
    (assert-truncation-at-every-split)
    (assert-nested-blob)
    (assert-length-limits)
    (assert-identification)
    (assert-banner-limits)
    (assert-identification-encoder)
    (assert-plans)
    (assert-clear-packets)
    (assert-malformed-packets)
    (assert-sealed-packets)
    (assert-sequence-wrap)
    (assert-decode-encode-idempotence)
    (assert-fragmentation-independence)
    42))