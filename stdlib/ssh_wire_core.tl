;# Bounded SSH-2 wire layer: the RFC 4251 data types, the RFC 4253
;# identification exchange and binary packet framing.
;#
;# This is the byte layer of the SSH client (#6977). It performs no I/O,
;# cryptography, randomness, trust decision or protocol policy; the transport,
;# authentication and channel layers drive it and give opaque fields their
;# meaning.
;#
;# - `SshDecoder` reads `byte`, `boolean`, `uint32`, `uint64`, `string`,
;#   `name-list` and positive `mpint` values from one borrowed view. A `string`
;#   is returned as an `SshSpan` into that view, never as text, and a nested
;#   blob is read with `decoder-sub` and must then be consumed completely.
;#   The `push-*` encoders append the same types to a `ByteBuf`.
;# - `SshIdentReader` takes the peer's identification line from input split
;#   anywhere, after at most a bounded number of other lines when the peer is
;#   a server. It keeps the line exactly as it was sent, without CR LF, which
;#   is what the exchange hash covers.
;# - `frame-plan` computes the padding a payload needs, and `encode-frame`
;#   builds the packet from padding bytes the caller supplies; this module
;#   never chooses padding bytes. `SshPacketReader` splits a byte stream into
;#   packets. In clear mode it validates each packet and returns its payload;
;#   in sealed mode it returns the clear length, the encrypted body and the
;#   tag, and only `open-plain-body` -- called on a body the caller has
;#   authenticated and decrypted -- yields a payload.
;#
;# Every length is checked against the protocol and the caller's
;# `SshWireLimits` before anything is copied or allocated, and the readers
;# buffer at most one line or one packet. A failure is an `SshWireError`: a
;# stable code and the byte offset it was found at. Offsets are stream offsets
;# for the readers and offsets into the decoded view for `SshDecoder`.
;# Encoders trap when a value cannot be expressed on the wire, the way
;# `byte_buf` traps on a bad range.
;#
;# Usage: `(import stdlib.ssh_wire_core)`
(import stdlib.byte_buf)
(import stdlib.string)

;; --- errors ------------------------------------------------------------------
;: Input ended inside a value.
(define error-truncated : i64
  1)

;: A length prefix exceeds the protocol maximum or a caller limit.
(define error-length-range : i64
  2)

;: Bytes remain after a value that must be consumed completely.
(define error-trailing : i64
  3)

;: A `name-list` element is empty, too long, or has a byte outside printable
;: US-ASCII, or the list has a leading, trailing or doubled comma.
(define error-name-list : i64
  4)

;: A `name-list` has more elements than the caller's limit.
(define error-too-many-names : i64
  5)

;: A positive `mpint` is negative.
(define error-mpint-negative : i64
  6)

;: An `mpint` is not in its minimal two's-complement form.
(define error-mpint-noncanonical : i64
  7)

;: A positive `mpint` is zero.
(define error-mpint-zero : i64
  8)

;: The identification line does not have the RFC 4253 section 4.2 form.
(define error-identification : i64
  9)

;: The identification line names a protocol version other than 2.0 or 1.99.
(define error-protocol-version : i64
  10)

;: A line is longer than its limit.
(define error-line-too-long : i64
  11)

;: The lines before the identification line exceed their count or byte limit.
(define error-banner-limit : i64
  12)

;: A packet length is below the minimum packet size or above the limit.
(define error-packet-length : i64
  13)

;: A packet length breaks the framing mode's block alignment.
(define error-packet-alignment : i64
  14)

;: A padding length is below 4 or leaves no room for a payload.
(define error-padding-length : i64
  15)

;: A packet carries no payload, so it has no message number.
(define error-empty-payload : i64
  16)

;: Padding bytes do not match the length `frame-plan` requires.
(define error-padding-mismatch : i64
  17)

;: A short name for an error code, for diagnostics.
(define (error-name [code : i64]) : String
  (cond
    [(= code error-truncated) "truncated"]
    [(= code error-length-range) "length out of range"]
    [(= code error-trailing) "trailing bytes"]
    [(= code error-name-list) "malformed name-list"]
    [(= code error-too-many-names) "too many names"]
    [(= code error-mpint-negative) "negative mpint"]
    [(= code error-mpint-noncanonical) "non-minimal mpint"]
    [(= code error-mpint-zero) "zero mpint"]
    [(= code error-identification) "malformed identification line"]
    [(= code error-protocol-version) "unsupported protocol version"]
    [(= code error-line-too-long) "line too long"]
    [(= code error-banner-limit) "too many lines before identification"]
    [(= code error-packet-length) "packet length out of range"]
    [(= code error-packet-alignment) "packet length misaligned"]
    [(= code error-padding-length) "padding length out of range"]
    [(= code error-empty-payload) "empty payload"]
    [(= code error-padding-mismatch) "padding does not match the plan"]
    [else "unknown error"]))

;: A codec failure: its stable `code` and the byte `offset` it was found at.
(defstruct SshWireError
  (code i64)
  (offset i64))

;: Copy an error out of a borrowed place.
(define (copy-error [error : (& error SshWireError)]) : SshWireError
  (SshWireError error.code error.offset))

;: The outcome of a check that produces no value.
(defenum SshWireCheck
  (SshWireOk)
  (SshWireErr SshWireError))

;; --- limits --------------------------------------------------------------------
;: The largest value a `uint32` holds, and so the largest length any SSH
;: length prefix states.
(define max-uint32 : i64
  4294967295)

;: The longest identification line RFC 4253 section 4.2 allows, CR LF included.
(define max-identification-line : i64
  255)

;: The longest name RFC 4251 section 6 allows in a `name-list`.
(define max-name-bytes : i64
  64)

;: Caller bounds, each positive: the identification line (CR LF included, at
;: most 255), the count, length and total size of the lines a server may send
;: before it, a packet's `packet_length`, and the size of one `string`, one
;: `name-list` with its element count, and one `mpint`.
(defstruct SshWireLimits
  (max-identification-bytes i64)
  (max-banner-lines i64)
  (max-banner-line-bytes i64)
  (max-banner-bytes i64)
  (max-packet-length i64)
  (max-string-bytes i64)
  (max-name-list-bytes i64)
  (max-name-list-entries i64)
  (max-mpint-bytes i64))

;: The RFC maxima and bounds that cover OpenSSH: a 255-byte identification
;: line after at most 1024 other lines of at most 8 KiB and 64 KiB in total,
;: 256 KiB packets, 256 KiB strings, 64 KiB name-lists of at most 256 names,
;: and 2 KiB mpints (16384-bit integers).
(define (default-limits) : SshWireLimits
  (SshWireLimits
    max-identification-line
    1024
    8192
    65536
    262144
    262144
    65536
    256
    2048))

;: Whether every limit is positive, the identification limit is at most 255,
;: and every length fits a `uint32`.
(define (limits-valid? [limits : (& limits SshWireLimits)]) : bool
  (and
    (> limits.max-identification-bytes 0)
    (<= limits.max-identification-bytes max-identification-line)
    (>= limits.max-banner-lines 0)
    (> limits.max-banner-line-bytes 0)
    (<= limits.max-banner-line-bytes max-uint32)
    (>= limits.max-banner-bytes 0)
    (<= limits.max-banner-bytes max-uint32)
    (> limits.max-packet-length 0)
    (<= limits.max-packet-length max-uint32)
    (> limits.max-string-bytes 0)
    (<= limits.max-string-bytes max-uint32)
    (> limits.max-name-list-bytes 0)
    (<= limits.max-name-list-bytes max-uint32)
    (> limits.max-name-list-entries 0)
    (> limits.max-mpint-bytes 0)
    (<= limits.max-mpint-bytes max-uint32)))

;: Trap unless `actual` equals `expected`: a caller passed a value the wire
;: cannot carry.
(define (check-equal [actual : i64] [expected : i64]) : unit
  (byte_buf.check-range expected expected (- actual expected)))

;: Return `limits`, trapping unless it satisfies `limits-valid?`.
(define (require-valid-limits [limits : SshWireLimits]) : SshWireLimits
  (check-equal
    (if (limits-valid? (& limits))
      1
      0)
    1)
  limits)

;; --- big-endian access ---------------------------------------------------------
;: The big-endian unsigned integer of `width` bytes (at most 7) at `offset` of
;: `view`. The caller has checked the range.
(define (read-be [view : (& view bytes)] [offset : i64] [width : i64]) : i64
  (let
    [value : i64 0]
    [index : i64 0]
    (while (< index width)
      (set!
        value
        (bit-or
          (shl value 8)
          (cast (byte_buf.bytes-ref view (+ offset index)) : i64)))
      (set! index (+ index 1)))
    value))

;: Append the low `width` bytes of `value`, most significant first.
(define (push-be [buf : byte_buf.ByteBuf] [value : i64] [width : i64]) : byte_buf.ByteBuf
  (let
    [out : byte_buf.ByteBuf buf]
    [shift : i64 (* 8 (- width 1))]
    (while (>= shift 0)
      (set! out (byte_buf.push out (cast (bit-and (shr value shift) 255) : u8)))
      (set! shift (- shift 8)))
    out))

;; --- decoding cursor -------------------------------------------------------------
;: A range of a borrowed view: `count` bytes from `start`.
(defstruct SshSpan
  (start i64)
  (count i64))

;: Copy a span out of a borrowed place.
(define (copy-span [span : (& span SshSpan)]) : SshSpan
  (SshSpan span.start span.count))

;: The bytes `span` covers in `view`.
(define (span-bytes [view : (& view bytes)] [span : (& span SshSpan)]) : (&
    view
    bytes)
  (byte_buf.bytes-slice-view view span.start span.count))

;: Whether `span` covers the same bytes of `view` as `text`.
(define (span-equals?
  [view : (& view bytes)]
  [span : (& span SshSpan)]
  [text : String]) : bool
  (let
    [expected : (& text bytes) (byte_buf.str-as-bytes (& text))]
    [count : i64 (byte_buf.bytes-length expected)]
    [index : i64 0]
    [same : bool (= count span.count)]
    (while (and same (< index count))
      (when
        (!=
          (byte_buf.bytes-ref view (+ span.start index))
          (byte_buf.bytes-ref expected index))
        (set! same false))
      (set! index (+ index 1)))
    same))

;: A cursor over `[pos, end)` of one borrowed view, which every call receives
;: again. The first failure is kept; later reads return zero values without
;: moving, so a decoder checks `failed` once after a run of reads.
(defstruct SshDecoder
  (pos i64)
  (end i64)
  (failed bool)
  (error SshWireError))

;: A cursor over the whole of `view`.
(define (decoder-new [view : (& view bytes)]) : SshDecoder
  (SshDecoder 0 (byte_buf.bytes-length view) false (SshWireError 0 0)))

;: A cursor over `span` of the same view, for a nested blob. Offsets stay
;: offsets into the whole view.
(define (decoder-sub [span : (& span SshSpan)]) : SshDecoder
  (SshDecoder span.start (+ span.start span.count) false (SshWireError 0 0)))

;: Record the first failure at `offset`; later ones are ignored.
(define (decoder-fail! [d : (&mut d SshDecoder)] [code : i64] [offset : i64]) : unit
  (when
    (not d.failed)
    (set! d.failed true)
    (set! d.error (SshWireError code offset))))

;: The bytes left before the cursor's end.
(define (decoder-remaining [d : (& d SshDecoder)]) : i64
  (- d.end d.pos))

;: Take `count` bytes and return their offset.
(define (decoder-take! [d : (&mut d SshDecoder)] [count : i64]) : i64
  (cond
    [d.failed 0]
    [(> count (- d.end d.pos))
      (decoder-fail! d error-truncated d.pos)
      0]
    [else
      (let
        [at : i64 d.pos]
        (set! d.pos (+ at count))
        at)]))

;: Read a `byte`.
(define (decoder-byte! [d : (&mut d SshDecoder)] [view : (& view bytes)]) : i64
  (let
    [at : i64 (decoder-take! d 1)]
    (if d.failed
      0
      (read-be view at 1))))

;: Read a `boolean`. RFC 4251 section 5 reads every non-zero byte as TRUE.
(define (decoder-boolean! [d : (&mut d SshDecoder)] [view : (& view bytes)]) : bool
  (!= (decoder-byte! d view) 0))

;: Read a `uint32`.
(define (decoder-uint32! [d : (&mut d SshDecoder)] [view : (& view bytes)]) : i64
  (let
    [at : i64 (decoder-take! d 4)]
    (if d.failed
      0
      (read-be view at 4))))

;: Read a `uint64`.
(define (decoder-uint64! [d : (&mut d SshDecoder)] [view : (& view bytes)]) : u64
  (let
    [at : i64 (decoder-take! d 8)]
    [value : u64 (cast 0 : u64)]
    [index : i64 0]
    (when
      (not d.failed)
      (while (< index 8)
        (set!
          value
          (bit-or
            (shl value (cast 8 : u64))
            (cast (byte_buf.bytes-ref view (+ at index)) : u64)))
        (set! index (+ index 1))))
    value))

;: Read a `string` of at most `max` bytes and return the span of its data.
;: The length is checked before anything else, so a hostile prefix costs no
;: work.
(define (decoder-string!
  [d : (&mut d SshDecoder)]
  [view : (& view bytes)]
  [max : i64]) : SshSpan
  (let
    [prefix-at : i64 d.pos]
    [length : i64 (decoder-uint32! d view)]
    (cond
      [d.failed (SshSpan 0 0)]
      [(> length max)
        (decoder-fail! d error-length-range prefix-at)
        (SshSpan 0 0)]
      [else
        (let
          [at : i64 (decoder-take! d length)]
          (if d.failed
            (SshSpan 0 0)
            (SshSpan at length)))])))

;: Require that the cursor consumed its range exactly.
(define (decoder-finish! [d : (&mut d SshDecoder)]) : unit
  (when
    (and (not d.failed) (!= d.pos d.end))
    (decoder-fail! d error-trailing d.pos)))

;; --- name-list -------------------------------------------------------------------
;: A decoded `name-list`: the span of the whole list data and the span of each
;: name in order. Names keep their bytes in the view; nothing is converted.
(defstruct SshNameList
  (data SshSpan)
  (names (__tl_dyn-array SshSpan)))

;: Whether `code` may appear in a name: printable US-ASCII other than space,
;: DEL and the comma separator (RFC 4251 section 6).
(define (name-byte? [code : i64]) : bool
  (and (> code 32) (< code 127) (!= code 44)))

;: Validate the name-list data `[start, start + count)` of `view`. Returns
;: the number of names, or records a failure and returns -1. Every name is
;: non-empty, at most `max-name-bytes` long and made of `name-byte?` bytes, so
;: no comma leads, trails or repeats.
(define (name-list-scan!
  [d : (&mut d SshDecoder)]
  [view : (& view bytes)]
  [start : i64]
  [count : i64]
  [max-names : i64]) : i64
  (let
    [names : i64 0]
    [name-start : i64 start]
    [index : i64 start]
    [end : i64 (+ start count)]
    [failed : bool false]
    (when
      (> count 0)
      (while (and (not failed) (<= index end))
        (if (or
          (= index end)
          (= (cast (byte_buf.bytes-ref view index) : i64) 44))
          (let
            [length : i64 (- index name-start)]
            (cond
              [(or (= length 0) (> length max-name-bytes))
                (decoder-fail! d error-name-list name-start)
                (set! failed true)]
              [(>= names max-names)
                (decoder-fail! d error-too-many-names name-start)
                (set! failed true)]
              [else
                (set! names (+ names 1))
                (set! name-start (+ index 1))]))
          (when
            (not (name-byte? (cast (byte_buf.bytes-ref view index) : i64)))
            (begin
              (decoder-fail! d error-name-list index)
              (set! failed true))))
        (set! index (+ index 1))))
    (if failed
      -1
      names)))

;: Read a `name-list` under `limits`. The list is validated completely before
;: its exact array of name spans is allocated.
(define (decoder-name-list!
  [d : (&mut d SshDecoder)]
  [view : (& view bytes)]
  [limits : (& limits SshWireLimits)]) : SshNameList
  (let
    [data : SshSpan (decoder-string! d view limits.max-name-list-bytes)]
    (if d.failed
      (SshNameList (SshSpan 0 0) (__tl_make-array SshSpan 0))
      (let
        [count : i64
          (name-list-scan!
            d
            view
            data.start
            data.count
            limits.max-name-list-entries)]
        (if (< count 0)
          (SshNameList (SshSpan 0 0) (__tl_make-array SshSpan 0))
          (let
            [names : (__tl_dyn-array SshSpan) (__tl_make-array SshSpan count)]
            [slot : i64 0]
            [name-start : i64 data.start]
            [index : i64 data.start]
            [end : i64 (+ data.start data.count)]
            (when
              (> count 0)
              (while (<= index end)
                (when
                  (or
                    (= index end)
                    (= (cast (byte_buf.bytes-ref view index) : i64) 44))
                  (set!
                    (array-ref names slot)
                    (SshSpan name-start (- index name-start)))
                  (set! slot (+ slot 1))
                  (set! name-start (+ index 1)))
                (set! index (+ index 1))))
            (SshNameList data names)))))))

;; --- mpint -------------------------------------------------------------------------
;: A positive `mpint`: the span of its encoded data, which a transcript hashes,
;: and the span of its magnitude without the leading zero byte RFC 4251 adds
;: when the high bit is set.
(defstruct SshMpint
  (data SshSpan)
  (magnitude SshSpan))

;: Read a positive `mpint` of at most `max` data bytes in minimal form: not
;: empty (zero), no high bit on the first byte (negative), and a leading zero
;: byte only when the next byte has its high bit set.
(define (decoder-mpint-positive!
  [d : (&mut d SshDecoder)]
  [view : (& view bytes)]
  [max : i64]) : SshMpint
  (let
    [prefix-at : i64 d.pos]
    [data : SshSpan (decoder-string! d view max)]
    (cond
      [d.failed (SshMpint (SshSpan 0 0) (SshSpan 0 0))]
      [(= data.count 0)
        (decoder-fail! d error-mpint-zero prefix-at)
        (SshMpint (SshSpan 0 0) (SshSpan 0 0))]
      [else
        (let
          [first : i64 (cast (byte_buf.bytes-ref view data.start) : i64)]
          (cond
            [(>= first 128)
              (decoder-fail! d error-mpint-negative data.start)
              (SshMpint (SshSpan 0 0) (SshSpan 0 0))]
            [(and
              (= first 0)
              (or
                (= data.count 1)
                (< (cast (byte_buf.bytes-ref view (+ data.start 1)) : i64) 128)))
              (decoder-fail! d error-mpint-noncanonical data.start)
              (SshMpint (SshSpan 0 0) (SshSpan 0 0))]
            [(= first 0)
              (SshMpint data (SshSpan (+ data.start 1) (- data.count 1)))]
            [else (SshMpint data data)]))])))

;; --- encoders --------------------------------------------------------------------
;: Append a `byte`; traps unless `value` is in 0..255.
(define (push-byte [out : byte_buf.ByteBuf] [value : i64]) : byte_buf.ByteBuf
  (byte_buf.check-range 255 0 value)
  (push-be out value 1))

;: Append a `boolean` as 1 or 0.
(define (push-boolean [out : byte_buf.ByteBuf] [value : bool]) : byte_buf.ByteBuf
  (push-be
    out
    (if value
      1
      0)
    1))

;: Append a `uint32`; traps unless `value` is in 0..2^32-1.
(define (push-uint32 [out : byte_buf.ByteBuf] [value : i64]) : byte_buf.ByteBuf
  (byte_buf.check-range max-uint32 0 value)
  (push-be out value 4))

;: Append a `uint64`.
(define (push-uint64 [out : byte_buf.ByteBuf] [value : u64]) : byte_buf.ByteBuf
  (let
    [result : byte_buf.ByteBuf out]
    [shift : i64 56]
    (while (>= shift 0)
      (set!
        result
        (byte_buf.push
          result
          (cast (bit-and (shr value (cast shift : u64)) (cast 255 : u64)) : u8)))
      (set! shift (- shift 8)))
    result))

;: Append `data` as a `string`.
(define (push-string [out : byte_buf.ByteBuf] [data : (& data bytes)]) : byte_buf.ByteBuf
  (let
    [length : i64 (byte_buf.bytes-length data)]
    (byte_buf.check-range max-uint32 0 length)
    (byte_buf.append-bytes (push-be out length 4) data)))

;: Append `names` as a `name-list`; traps unless every name is valid for
;: `name-list-scan!`.
(define (push-name-list
  [out : byte_buf.ByteBuf]
  [names : (& names (__tl_dyn-array String))]) : byte_buf.ByteBuf
  (let
    [data : byte_buf.ByteBuf (byte_buf.new)]
    [index : i64 0]
    (while (< index (array-length names))
      (let
        [name : (& names bytes)
          (byte_buf.str-as-bytes (& (array-ref names index)))]
        [length : i64 (byte_buf.bytes-length name)]
        [byte-index : i64 0]
        (byte_buf.check-range max-name-bytes 1 (- length 1))
        (while (< byte-index length)
          (check-equal
            (if (name-byte? (cast (byte_buf.bytes-ref name byte-index) : i64))
              1
              0)
            1)
          (set! byte-index (+ byte-index 1)))
        (when (> index 0) (set! data (byte_buf.push data (cast 44 : u8))))
        (set! data (byte_buf.append-bytes data name))
        (set! index (+ index 1))))
    (push-string out (byte_buf.as-bytes (& data)))))

;: Append the positive integer whose big-endian magnitude is `magnitude` as a
;: minimal `mpint`. Leading zero bytes are dropped and one is added back when
;: the high bit is set. Traps when the value is zero.
(define (push-mpint-positive
  [out : byte_buf.ByteBuf]
  [magnitude : (& magnitude bytes)]) : byte_buf.ByteBuf
  (let
    [length : i64 (byte_buf.bytes-length magnitude)]
    [first : i64 0]
    (while (and
      (< first length)
      (= (cast (byte_buf.bytes-ref magnitude first) : i64) 0))
      (set! first (+ first 1)))
    (check-equal
      (if (< first length)
        1
        0)
      1)
    (let
      [digits : (& magnitude bytes)
        (byte_buf.bytes-slice-view magnitude first (- length first))]
      [high : bool (>= (cast (byte_buf.bytes-ref magnitude first) : i64) 128)]
      [count : i64
        (+
          (- length first)
          (if high
            1
            0))]
      (byte_buf.check-range max-uint32 0 count)
      (byte_buf.append-bytes
        (if high
          (byte_buf.push (push-be out count 4) (cast 0 : u8))
          (push-be out count 4))
        digits))))

;; --- reader buffers ----------------------------------------------------------------
;: Grow the storage of `buf` to hold at least `capacity` bytes, at least
;: doubling it.
(define (buffer-reserve! [buf : (&mut buf byte_buf.ByteBuf)] [capacity : i64]) : unit
  (let
    [current : i64 (byte_buf.capacity buf)]
    (when
      (> capacity current)
      (set!
        (deref buf)
        (byte_buf.append-bytes
          (byte_buf.with-capacity
            (if (< capacity (* 2 current))
              (* 2 current)
              capacity))
          (byte_buf.as-bytes buf))))))

;: Append `count` bytes of `src` from `start` to `buf`.
(define (buffer-append!
  [buf : (&mut buf byte_buf.ByteBuf)]
  [src : (& src bytes)]
  [start : i64]
  [count : i64]) : unit
  (let
    [old-len : i64 buf.len]
    (byte_buf.check-range (byte_buf.bytes-length src) start count)
    (buffer-reserve! buf (+ old-len count))
    ;; The source range was checked above and the storage now holds
    ;; `old-len + count` bytes: the same copy `byte_buf.append-bytes-range`
    ;; makes, into storage reached through `&mut`.
    (string.str-copy-bytes-into
      (unsafe
        (ptr-offset (byte_buf.bytes-data src) start))
      (unsafe
        (__tl_array-data buf.slots))
      old-len
      count)
    (set! buf.len (+ old-len count))))

;; --- identification exchange ---------------------------------------------------------
;: The fields of an identification line `SSH-protoversion-softwareversion
;: [SP comments]`, as spans of the line without its CR LF. `comments` is
;: empty and `has-comments` false when the line has no space.
(defstruct SshIdentification
  (protoversion SshSpan)
  (software SshSpan)
  (has-comments bool)
  (comments SshSpan))

;: Whether `line` (CR LF excluded) starts with `SSH-`.
(define (ssh-prefix? [line : (& line bytes)]) : bool
  (let
    [prefix : SshSpan (SshSpan 0 4)]
    (and
      (>= (byte_buf.bytes-length line) 4)
      (span-equals? line (& prefix) "SSH-"))))

;: The outcome of `parse-identification`.
(defenum SshIdentParse
  (SshIdentParseOk SshIdentification)
  (SshIdentParseErr SshWireError))

;: Parse an identification line without its CR LF; a failure is reported at
;: `base` plus the offending index.
(define (parse-identification [line : (& line bytes)] [base : i64]) : SshIdentParse
  (let
    [length : i64 (byte_buf.bytes-length line)]
    [dash : i64 4]
    (when
      (not (ssh-prefix? line))
      (return (SshIdentParseErr (SshWireError error-identification base))))
    (while (and
      (< dash length)
      (!= (cast (byte_buf.bytes-ref line dash) : i64) 45))
      (set! dash (+ dash 1)))
    (when
      (>= dash length)
      (return (SshIdentParseErr (SshWireError error-identification base))))
    (let
      [protoversion : SshSpan (SshSpan 4 (- dash 4))]
      [software-start : i64 (+ dash 1)]
      [software-end : i64 software-start]
      (when
        (not
          (or
            (span-equals? line (& protoversion) "2.0")
            (span-equals? line (& protoversion) "1.99")))
        (return
          (SshIdentParseErr (SshWireError error-protocol-version (+ base 4)))))
      (while (and
        (< software-end length)
        (!= (cast (byte_buf.bytes-ref line software-end) : i64) 32))
        (let
          [code : i64 (cast (byte_buf.bytes-ref line software-end) : i64)]
          (when
            (or (<= code 32) (>= code 127) (= code 45))
            (return
              (SshIdentParseErr
                (SshWireError error-identification (+ base software-end)))))
          (set! software-end (+ software-end 1))))
      (when
        (= software-end software-start)
        (return
          (SshIdentParseErr
            (SshWireError error-identification (+ base software-start)))))
      (let
        [comment-start : i64 (+ software-end 1)]
        [index : i64 comment-start]
        (while (< index length)
          (let
            [code : i64 (cast (byte_buf.bytes-ref line index) : i64)]
            (when
              (or (< code 32) (>= code 127))
              (return
                (SshIdentParseErr
                  (SshWireError error-identification (+ base index)))))
            (set! index (+ index 1))))
        (SshIdentParseOk
          (SshIdentification
            protoversion
            (SshSpan software-start (- software-end software-start))
            (< software-end length)
            (if (< software-end length)
              (SshSpan comment-start (- length comment-start))
              (SshSpan length 0))))))))

;: One step of `ident-reader-next!`: `consumed` input bytes were taken.
;: `SshIdentBanner` means a whole line other than the identification was
;: read; `SshIdentComplete` means the identification line was.
(defenum SshIdentStep
  (SshIdentNeedMore i64)
  (SshIdentBanner i64)
  (SshIdentComplete i64)
  (SshIdentFailed SshWireError))

;: Incremental reader of the peer's identification. Each call takes bytes up
;: to the end of one line, so the bytes after the identification line -- the
;: first binary packet -- stay with the caller. The last complete line stays
;: readable through `ident-reader-line` until the next call. After a failure
;: the reader returns that failure for all further input.
(defstruct SshIdentReader
  (limits SshWireLimits)
  (accept-banner bool)
  (line byte_buf.ByteBuf)
  (line-start i64)
  (line-done bool)
  (banner-lines i64)
  (banner-bytes i64)
  (identification SshIdentification)
  (complete bool)
  (failed bool)
  (error SshWireError))

;: A reader at the start of a stream. `accept-banner` admits the lines a
;: server may send before its identification (RFC 4253 section 4.2); a server
;: reading a client passes false. Traps unless `limits` satisfies
;: `limits-valid?`.
(define (ident-reader-new [limits : SshWireLimits] [accept-banner : bool]) : SshIdentReader
  (SshIdentReader
    (require-valid-limits limits)
    accept-banner
    (byte_buf.with-capacity 0)
    0
    false
    0
    0
    (SshIdentification (SshSpan 0 0) (SshSpan 0 0) false (SshSpan 0 0))
    false
    false
    (SshWireError 0 0)))

;: Enter the failed state with `error`, returning it as a step.
(define (ident-reader-fail!
  [reader : (&mut reader SshIdentReader)]
  [error : SshWireError]) : SshIdentStep
  (set! reader.failed true)
  (set! reader.error (copy-error (& error)))
  (SshIdentFailed error))

;: Whether `line` is shorter than 4 bytes and every byte it has matches
;: `SSH-`, so it may still become an identification line.
(define (ssh-prefix-candidate? [line : (& line bytes)]) : bool
  (let
    [length : i64 (byte_buf.bytes-length line)]
    [text : String "SSH-"]
    [prefix : (& text bytes) (byte_buf.str-as-bytes (& text))]
    [index : i64 0]
    [same : bool (< length 4)]
    (while (and same (< index length))
      (when
        (!= (byte_buf.bytes-ref line index) (byte_buf.bytes-ref prefix index))
        (set! same false))
      (set! index (+ index 1)))
    same))

;: The most bytes the current line may grow to, its terminator included: the
;: identification limit for a line that starts with `SSH-`, the banner line
;: limit for any other line, and the larger of the two while the first bytes
;: still match `SSH-`.
(define (ident-reader-line-cap [reader : (& reader SshIdentReader)]) : i64
  (let
    [line : (& reader bytes) (byte_buf.as-bytes (& reader.line))]
    [identification : i64 reader.limits.max-identification-bytes]
    [banner : i64 reader.limits.max-banner-line-bytes]
    (cond
      [(not reader.accept-banner) identification]
      [(ssh-prefix? line) identification]
      [(ssh-prefix-candidate? line)
        (if (> banner identification)
          banner
          identification)]
      [else banner])))

;: Take bytes of `input` up to the end of the current line: returns
;: `SshIdentNeedMore` when `input` ran out first, `SshIdentBanner` or
;: `SshIdentComplete` when a line ended, or `SshIdentFailed`. The caller passes
;: the unconsumed rest of `input` to the next call. Once the identification is
;: complete the reader takes nothing more.
(define (ident-reader-next!
  [reader : (&mut reader SshIdentReader)]
  [input : (& input bytes)]) : SshIdentStep
  (when reader.failed (return (SshIdentFailed (copy-error (& reader.error)))))
  (when reader.complete (return (SshIdentComplete 0)))
  (when
    reader.line-done
    (set!
      reader.line-start
      (+ reader.line-start (byte_buf.len (& reader.line))))
    (set! reader.line.len 0)
    (set! reader.line-done false))
  (let
    [available : i64 (byte_buf.bytes-length input)]
    [cap : i64 (ident-reader-line-cap reader)]
    [room : i64 (- cap (byte_buf.len (& reader.line)))]
    [index : i64 0]
    [found : bool false]
    (while (and (not found) (< index available) (< index room))
      (if (= (cast (byte_buf.bytes-ref input index) : i64) 10)
        (set! found true)
        (set! index (+ index 1))))
    (let
      [take : i64
        (if found
          (+ index 1)
          index)]
      (buffer-append! (&mut reader.line) input 0 take)
      (when
        (not found)
        (return
          (if (>= (byte_buf.len (& reader.line)) (ident-reader-line-cap reader))
            (ident-reader-fail!
              reader
              (SshWireError error-line-too-long reader.line-start))
            (SshIdentNeedMore take))))
      (let
        [raw : (& reader bytes) (byte_buf.as-bytes (& reader.line))]
        [raw-length : i64 (byte_buf.bytes-length raw)]
        (if (ssh-prefix? raw)
          (cond
            [(> raw-length reader.limits.max-identification-bytes)
              (ident-reader-fail!
                reader
                (SshWireError error-line-too-long reader.line-start))]
            [(or
                (< raw-length 2)
                (!= (cast (byte_buf.bytes-ref raw (- raw-length 2)) : i64) 13))
              (ident-reader-fail!
                reader
                (SshWireError
                  error-identification
                  (+ reader.line-start (- raw-length 1))))]
            [else
              (match (parse-identification
                (byte_buf.bytes-slice-view raw 0 (- raw-length 2))
                reader.line-start)
                [(SshIdentParseErr error) (ident-reader-fail! reader error)]
                [(SshIdentParseOk identification)
                  (set! reader.identification identification)
                  (set! reader.complete true)
                  (set! reader.line-done true)
                  (SshIdentComplete take)])])
          (cond
            [(not reader.accept-banner)
              (ident-reader-fail!
                reader
                (SshWireError error-identification reader.line-start))]
            [(> raw-length reader.limits.max-banner-line-bytes)
              (ident-reader-fail!
                reader
                (SshWireError error-line-too-long reader.line-start))]
            [(or
                (>= reader.banner-lines reader.limits.max-banner-lines)
                (>
                  (+ reader.banner-bytes raw-length)
                  reader.limits.max-banner-bytes))
              (ident-reader-fail!
                reader
                (SshWireError error-banner-limit reader.line-start))]
            [else
              (set! reader.banner-lines (+ reader.banner-lines 1))
              (set! reader.banner-bytes (+ reader.banner-bytes raw-length))
              (set! reader.line-done true)
              (SshIdentBanner take)]))))))

;: The line the last `SshIdentBanner` or `SshIdentComplete` step finished,
;: without its line terminator: for the identification, exactly the bytes the
;: exchange hash covers. Banner lines keep a CR that preceded their LF out.
(define (ident-reader-line [reader : (& reader SshIdentReader)]) : (&
    reader
    bytes)
  (let
    [raw : (& reader bytes) (byte_buf.as-bytes (& reader.line))]
    [length : i64 (byte_buf.bytes-length raw)]
    [end : i64
      (if (and
        (> length 0)
        (= (cast (byte_buf.bytes-ref raw (- length 1)) : i64) 10))
        (if (and
          (> length 1)
          (= (cast (byte_buf.bytes-ref raw (- length 2)) : i64) 13))
          (- length 2)
          (- length 1))
        length)]
    (byte_buf.bytes-slice-view raw 0 end)))

;: The fields of the identification line, once `SshIdentComplete`.
(define (ident-reader-identification [reader : (& reader SshIdentReader)]) : SshIdentification
  (SshIdentification
    (copy-span (& reader.identification.protoversion))
    (copy-span (& reader.identification.software))
    reader.identification.has-comments
    (copy-span (& reader.identification.comments))))

;: The stream offset of the current line.
(define (ident-reader-offset [reader : (& reader SshIdentReader)]) : i64
  reader.line-start)

;: Append the identification line `SSH-2.0-software[ comments]` and its CR
;: LF. Traps unless `software` is non-empty printable US-ASCII without spaces
;: or `-`, `comments` is printable US-ASCII, and the line fits 255 bytes.
(define (encode-identification
  [out : byte_buf.ByteBuf]
  [software : String]
  [comments : String]) : byte_buf.ByteBuf
  (let
    [line : byte_buf.ByteBuf (byte_buf.from-string "SSH-2.0-")]
    [software-bytes : (& software bytes) (byte_buf.str-as-bytes (& software))]
    [comment-bytes : (& comments bytes) (byte_buf.str-as-bytes (& comments))]
    (set! line (byte_buf.append-bytes line software-bytes))
    (when
      (> (byte_buf.bytes-length comment-bytes) 0)
      (set!
        line
        (byte_buf.append-bytes
          (byte_buf.push line (cast 32 : u8))
          comment-bytes)))
    (match (parse-identification (byte_buf.as-bytes (& line)) 0)
      [(SshIdentParseErr _) (check-equal 0 1)]
      [(SshIdentParseOk identification)
        (check-equal
          (if (=
            identification.software.count
            (byte_buf.bytes-length software-bytes))
            1
            0)
          1)])
    (byte_buf.check-range
      (- max-identification-line 2)
      0
      (byte_buf.len (& line)))
    (let
      [terminated : byte_buf.ByteBuf
        (byte_buf.push (byte_buf.push line (cast 13 : u8)) (cast 10 : u8))]
      (byte_buf.append-bytes out (byte_buf.as-bytes (& terminated))))))

;; --- binary packet framing -------------------------------------------------------------
;: How packets are aligned and sealed (RFC 4253 section 6, RFC 5647).
;: `SshFrameClear` is the unencrypted framing before the first NEWKEYS: the
;: whole packet, length field included, is a multiple of 8 bytes and there is
;: no MAC. `SshFrameAesGcm` is `aes128-gcm@openssh.com`: the 4-byte length
;: stays clear as associated data, `packet_length` is a multiple of 16, and a
;: 16-byte tag follows the encrypted body.
(defenum SshFrameMode
  (SshFrameClear)
  (SshFrameAesGcm))

;: The bytes of the clear `packet_length` field.
(define frame-header-length : i64
  4)

;: The fewest padding bytes a packet may carry.
(define min-padding-length : i64
  4)

;: The most padding bytes a packet may carry.
(define max-padding-length : i64
  255)

;: The tag length of `mode`.
(define (mode-tag-length [mode : (& mode SshFrameMode)]) : i64
  (match mode
    [(SshFrameClear) 0]
    [(SshFrameAesGcm) 16]))

;: The smallest `packet_length` of `mode`: a clear packet is at least 16
;: bytes with its length field, and an AES-GCM body at least one block.
(define (mode-min-packet-length [mode : (& mode SshFrameMode)]) : i64
  (match mode
    [(SshFrameClear) 12]
    [(SshFrameAesGcm) 16]))

;: Whether `packet-length` meets the alignment of `mode`.
(define (packet-length-aligned?
  [mode : (& mode SshFrameMode)]
  [packet-length : i64]) : bool
  (match mode
    [(SshFrameClear) (= (% (+ frame-header-length packet-length) 8) 0)]
    [(SshFrameAesGcm) (= (% packet-length 16) 0)]))

;: The lengths of one outgoing packet: `packet_length` and the padding it
;: holds.
(defstruct SshFramePlan
  (packet-length i64)
  (padding-length i64))

;: The outcome of `frame-plan`.
(defenum SshFramePlanResult
  (SshFramePlanOk SshFramePlan)
  (SshFramePlanErr SshWireError))

;: The packet lengths for a payload of `payload-length` bytes in `mode`: the
;: fewest padding bytes, at least 4, that align the packet and reach the
;: minimum packet size. Fails without allocating when the payload is empty or
;: the packet would exceed `limits.max-packet-length`.
(define (frame-plan
  [mode : (& mode SshFrameMode)]
  [payload-length : i64]
  [limits : (& limits SshWireLimits)]) : SshFramePlanResult
  (cond
    [(< payload-length 1)
      (SshFramePlanErr (SshWireError error-empty-payload 0))]
    [(> payload-length limits.max-packet-length)
      (SshFramePlanErr (SshWireError error-packet-length 0))]
    [else
      (let
        [padding : i64 min-padding-length]
        [packet-length : i64 (+ (+ 1 payload-length) min-padding-length)]
        (while (or
          (not (packet-length-aligned? mode packet-length))
          (< packet-length (mode-min-packet-length mode)))
          (set! padding (+ padding 1))
          (set! packet-length (+ packet-length 1)))
        (if (> packet-length limits.max-packet-length)
          (SshFramePlanErr (SshWireError error-packet-length 0))
          (SshFramePlanOk (SshFramePlan packet-length padding))))]))

;: The outcome of `encode-frame`: the packet without its tag, or why none
;: was built.
(defenum SshFrameResult
  (SshFrameOk byte_buf.ByteBuf)
  (SshFrameErr SshWireError))

;: The packet `uint32 packet_length || byte padding_length || payload ||
;: padding` for `payload` in `mode`, with exactly the `padding` bytes the
;: caller supplies. Fails before building anything unless `padding` has the
;: length `frame-plan` requires. In AES-GCM mode the first 4 bytes are the
;: associated data and the rest is the plaintext to seal; the tag is the
;: transform's to append.
(define (encode-frame
  [mode : (& mode SshFrameMode)]
  [payload : (& payload bytes)]
  [padding : (& padding bytes)]
  [limits : (& limits SshWireLimits)]) : SshFrameResult
  (match (frame-plan mode (byte_buf.bytes-length payload) limits)
    [(SshFramePlanErr error) (SshFrameErr error)]
    [(SshFramePlanOk plan)
      (if (!= (byte_buf.bytes-length padding) plan.padding-length)
        (SshFrameErr (SshWireError error-padding-mismatch 0))
        (let
          [out : byte_buf.ByteBuf
            (byte_buf.with-capacity (+ frame-header-length plan.packet-length))]
          (SshFrameOk
            (byte_buf.append-bytes
              (byte_buf.append-bytes
                (push-be
                  (push-be out plan.packet-length 4)
                  plan.padding-length
                  1)
                payload)
              padding))))]))

;: The payload and padding of a packet body, as spans of the body.
(defstruct SshPacketBody
  (payload SshSpan)
  (padding SshSpan))

;: The outcome of `open-plain-body`.
(defenum SshBodyResult
  (SshBodyOk SshPacketBody)
  (SshBodyErr SshWireError))

;: Validate a plaintext packet body `byte padding_length || payload ||
;: padding` of `packet_length` bytes: the padding is at least 4 bytes and
;: leaves a payload of at least one byte. Failures are reported at `base` plus
;: the offending index. Call it on a sealed packet's body only after the
;: transform has authenticated and decrypted it.
(define (open-plain-body [body : (& body bytes)] [base : i64]) : SshBodyResult
  (let
    [length : i64 (byte_buf.bytes-length body)]
    (if (< length 1)
      (SshBodyErr (SshWireError error-truncated base))
      (let
        [padding : i64 (cast (byte_buf.bytes-ref body 0) : i64)]
        [payload : i64 (- (- length 1) padding)]
        (cond
          [(< padding min-padding-length)
            (SshBodyErr (SshWireError error-padding-length base))]
          [(< payload 0) (SshBodyErr (SshWireError error-padding-length base))]
          [(= payload 0) (SshBodyErr (SshWireError error-empty-payload base))]
          [else
            (SshBodyOk
              (SshPacketBody
                (SshSpan 1 payload)
                (SshSpan (+ 1 payload) padding)))])))))

;: One step of `packet-reader-next!`: `consumed` input bytes were taken, and
;: `SshPacketComplete` means they finished a packet.
(defenum SshPacketStep
  (SshPacketNeedMore i64)
  (SshPacketComplete i64)
  (SshPacketFailed SshWireError))

;: Incremental packet framing. Each call takes bytes only up to the end of
;: one packet, checking the length field before buffering the body, so the
;: buffer never holds more than one packet. A completed packet stays readable
;: until the next call. The sequence number counts packets from zero and
;: wraps at 2^32 (RFC 4253 section 6.4). After a failure the reader returns
;: that failure for all further input.
(defstruct SshPacketReader
  (limits SshWireLimits)
  (mode SshFrameMode)
  (header byte_buf.ByteBuf)
  (body byte_buf.ByteBuf)
  (packet-length i64)
  (header-done bool)
  (ready bool)
  (sequence i64)
  (stream-offset i64)
  (plain SshPacketBody)
  (failed bool)
  (error SshWireError))

;: A reader at the start of a stream in `mode`. Traps unless `limits`
;: satisfies `limits-valid?`.
(define (packet-reader-new [limits : SshWireLimits] [mode : SshFrameMode]) : SshPacketReader
  (SshPacketReader
    (require-valid-limits limits)
    mode
    (byte_buf.with-capacity frame-header-length)
    (byte_buf.with-capacity 0)
    0
    false
    false
    0
    0
    (SshPacketBody (SshSpan 0 0) (SshSpan 0 0))
    false
    (SshWireError 0 0)))

;: Enter the failed state with `error`, returning it as a step.
(define (packet-reader-fail!
  [reader : (&mut reader SshPacketReader)]
  [error : SshWireError]) : SshPacketStep
  (set! reader.failed true)
  (set! reader.error (copy-error (& error)))
  (SshPacketFailed error))

;: Drop the completed packet so the next one can start.
(define (packet-reader-release! [reader : (&mut reader SshPacketReader)]) : unit
  (set!
    reader.stream-offset
    (+
      reader.stream-offset
      (+ frame-header-length (byte_buf.len (& reader.body)))))
  (set!
    reader.sequence
    (if (= reader.sequence max-uint32)
      0
      (+ reader.sequence 1)))
  (set! reader.header.len 0)
  (set! reader.body.len 0)
  (set! reader.header-done false)
  (set! reader.ready false))

;: Whether part of a packet is buffered, which at the end of the stream means
;: the peer truncated it.
(define (packet-reader-mid-packet? [reader : (& reader SshPacketReader)]) : bool
  (and (not reader.ready) (> (byte_buf.len (& reader.header)) 0)))

;: Switch framing for the packets after the current one, as NEWKEYS does.
;: Traps while part of a packet is buffered.
(define (packet-reader-set-mode!
  [reader : (&mut reader SshPacketReader)]
  [mode : SshFrameMode]) : unit
  (check-equal
    (if (packet-reader-mid-packet? reader)
      0
      1)
    1)
  (set! reader.mode mode))

;: Take bytes of `input` into the current packet, stopping at its end: returns
;: `SshPacketComplete` once the packet is whole, `SshPacketNeedMore` when
;: `input` ran out first, or `SshPacketFailed`. A clear packet is validated
;: here; a sealed one is validated by `open-plain-body` after the transform.
;: The caller passes the unconsumed rest of `input` to the next call.
(define (packet-reader-next!
  [reader : (&mut reader SshPacketReader)]
  [input : (& input bytes)]) : SshPacketStep
  (when reader.failed (return (SshPacketFailed (copy-error (& reader.error)))))
  (when reader.ready (packet-reader-release! reader))
  (let
    [available : i64 (byte_buf.bytes-length input)]
    [consumed : i64 0]
    (when
      (not reader.header-done)
      (let
        [want : i64 (- frame-header-length (byte_buf.len (& reader.header)))]
        [take : i64
          (if (< want available)
            want
            available)]
        (buffer-append! (&mut reader.header) input 0 take)
        (set! consumed take)
        (when
          (< (byte_buf.len (& reader.header)) frame-header-length)
          (return (SshPacketNeedMore consumed)))
        (let
          [length : i64
            (read-be
              (byte_buf.as-bytes (& reader.header))
              0
              frame-header-length)]
          (cond
            [(or
                (< length (mode-min-packet-length (& reader.mode)))
                (> length reader.limits.max-packet-length))
              (return
                (packet-reader-fail!
                  reader
                  (SshWireError error-packet-length reader.stream-offset)))]
            [(not (packet-length-aligned? (& reader.mode) length))
              (return
                (packet-reader-fail!
                  reader
                  (SshWireError error-packet-alignment reader.stream-offset)))]
            [else
              (buffer-reserve!
                (&mut reader.body)
                (+ length (mode-tag-length (& reader.mode))))
              (set! reader.packet-length length)
              (set! reader.header-done true)]))))
    (let
      [total : i64 (+ reader.packet-length (mode-tag-length (& reader.mode)))]
      [want : i64 (- total (byte_buf.len (& reader.body)))]
      [left : i64 (- available consumed)]
      [take : i64
        (if (< want left)
          want
          left)]
      (buffer-append! (&mut reader.body) input consumed take)
      (set! consumed (+ consumed take))
      (cond
        [(< (byte_buf.len (& reader.body)) total) (SshPacketNeedMore consumed)]
        [(= (mode-tag-length (& reader.mode)) 0)
          (match (open-plain-body
            (byte_buf.as-bytes (& reader.body))
            (+ reader.stream-offset frame-header-length))
            [(SshBodyErr error) (packet-reader-fail! reader error)]
            [(SshBodyOk body)
              (set! reader.plain body)
              (set! reader.ready true)
              (SshPacketComplete consumed)])]
        [else
          (set! reader.ready true)
          (SshPacketComplete consumed)]))))

;: The sequence number of the packet the last step completed, or of the next
;: packet before one completes.
(define (packet-reader-sequence [reader : (& reader SshPacketReader)]) : i64
  reader.sequence)

;: The stream offset of the current packet's length field.
(define (packet-reader-offset [reader : (& reader SshPacketReader)]) : i64
  reader.stream-offset)

;: The completed packet's `packet_length`.
(define (packet-reader-packet-length [reader : (& reader SshPacketReader)]) : i64
  reader.packet-length)

;: The completed packet's 4 length bytes: the associated data of a sealed
;: packet.
(define (packet-reader-header [reader : (& reader SshPacketReader)]) : (&
    reader
    bytes)
  (byte_buf.as-bytes (& reader.header)))

;: The completed packet's `packet_length` body bytes: the plaintext body of a
;: clear packet, the ciphertext of a sealed one.
(define (packet-reader-body [reader : (& reader SshPacketReader)]) : (&
    reader
    bytes)
  (byte_buf.bytes-slice-view
    (byte_buf.as-bytes (& reader.body))
    0
    reader.packet-length))

;: The completed sealed packet's tag; empty in clear mode.
(define (packet-reader-tag [reader : (& reader SshPacketReader)]) : (&
    reader
    bytes)
  (byte_buf.bytes-slice-view
    (byte_buf.as-bytes (& reader.body))
    reader.packet-length
    (- (byte_buf.len (& reader.body)) reader.packet-length)))

;: The completed clear packet's payload, which starts with its message
;: number. Empty in sealed mode, whose payload `open-plain-body` finds in the
;: decrypted body.
(define (packet-reader-payload [reader : (& reader SshPacketReader)]) : (&
    reader
    bytes)
  (if (= (mode-tag-length (& reader.mode)) 0)
    (byte_buf.bytes-slice-view
      (byte_buf.as-bytes (& reader.body))
      reader.plain.payload.start
      reader.plain.payload.count)
    (byte_buf.bytes-slice-view (byte_buf.as-bytes (& reader.body)) 0 0)))

;: The completed clear packet's padding bytes, which this module never
;: interprets.
(define (packet-reader-padding [reader : (& reader SshPacketReader)]) : (&
    reader
    bytes)
  (if (= (mode-tag-length (& reader.mode)) 0)
    (byte_buf.bytes-slice-view
      (byte_buf.as-bytes (& reader.body))
      reader.plain.padding.start
      reader.plain.padding.count)
    (byte_buf.bytes-slice-view (byte_buf.as-bytes (& reader.body)) 0 0)))