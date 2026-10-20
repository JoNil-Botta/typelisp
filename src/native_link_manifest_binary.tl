;# Canonical native-link v1 framing. Parsing preflights the complete tree before
;# retaining any input-sized allocation. Bounds use subtraction, never wrapped
;# offset+length arithmetic. stdlib.serialize owns the typed record traversal.
(import native_link_manifest_wire as wire)
(import stdlib.byte_le as le)
(import stdlib.byte_reader as bytes)
(import stdlib.byte_buf_core as buf)
(import stdlib.string)
(import stdlib.iterator)

(defenum DocumentKind
  (ManifestDocument)
  (ProfileDocument)
  (SemanticInputDocument))

(defstruct Limits
  (max-bytes i64)
  (max-nodes i64)
  (max-depth i64)
  (max-string-bytes i64)
  (max-record-fields i64)
  (max-work i64)
  (max-retained-bytes i64))

(define (default-limits) : Limits
  (Limits 33554432 262144 48 16777216 64 268435456 536870912))

(defenum ErrorKind
  (InvalidLimit)
  (Truncated)
  (BadDomain)
  (BadVersion)
  (BadDocumentKind)
  (BadLength)
  (BadTag)
  (BadBoolean)
  (BadInteger)
  (BadKeyOrder)
  (ByteLimit)
  (NodeLimit)
  (DepthLimit)
  (StringLimit)
  (FieldLimit)
  (WorkLimit)
  (RetainedLimit)
  (TrailingBytes))

(defstruct Error
  (kind ErrorKind)
  (offset i64))

(defstruct Scan
  (ok bool)
  (error Error)
  (offset i64)
  (nodes i64)
  (strings i64)
  (work i64)
  (retained i64)
  (limits Limits))

(defenum DecodeResult
  (Decoded wire.Value)
  (DecodeFailed Error))

(defenum EncodeResult
  (Encoded (__tl_dyn-array u8))
  (EncodeFailed Error))

(define (fail! [s : (&mut s Scan)] [kind : ErrorKind] [offset : i64]) : unit
  (when s.ok (set! s.ok false) (set! s.error (Error kind offset))))

(define (valid-limits? [x : (& x Limits)]) : bool
  (and
    (>= x.max-bytes 0)
    (>= x.max-nodes 0)
    (>= x.max-depth 0)
    (<= x.max-depth 64)
    (>= x.max-string-bytes 0)
    (>= x.max-record-fields 0)
    (<= x.max-record-fields 64)
    (>= x.max-work 0)
    (>= x.max-retained-bytes 0)))

(define (new-scan [limits : (& l Limits)]) : Scan
  (Scan true (Error (Truncated) 0) 0 0 0 0 0 (clone (deref limits))))

(define (charge! [s : (&mut s Scan)] [amount : i64] [retained : i64]) : unit
  (when
    s.ok
    (if (or (< amount 0) (> amount (- s.limits.max-work s.work)))
      (fail! s (WorkLimit) s.offset)
      (set! s.work (+ s.work amount)))
    (if (or
      (< retained 0)
      (> retained (- s.limits.max-retained-bytes s.retained)))
      (fail! s (RetainedLimit) s.offset)
      (set! s.retained (+ s.retained retained)))))

(define (string-charge! [s : (&mut s Scan)] [count : i64]) : unit
  (if (or (< count 0) (> count (- s.limits.max-string-bytes s.strings)))
    (fail! s (StringLimit) s.offset)
    (begin
      (set! s.strings (+ s.strings count))
      (if (> count (/ (- s.limits.max-retained-bytes s.retained) 256))
        (fail! s (RetainedLimit) s.offset)
        (charge! s count (* count 256))))))

(define (take!
  [_data : (& b (__tl_dyn-array u8))]
  [s : (&mut s Scan)]
  [end : i64]
  [count : i64]) : i64
  (let
    [start : i64 s.offset]
    (when
      s.ok
      (if (not (bytes.range-present? end start count))
        (fail! s (Truncated) start)
        (begin
          (set! s.offset (+ start count))
          (charge! s count 0))))
    start))

(define (u32!
  [data : (& b (__tl_dyn-array u8))]
  [s : (&mut s Scan)]
  [end : i64]) : i64
  (let
    [at : i64 (take! data s end 4)]
    (if s.ok
      (le.read-u32 data at)
      0)))

(define (u64!
  [data : (& b (__tl_dyn-array u8))]
  [s : (&mut s Scan)]
  [end : i64]) : i64
  (let
    [at : i64 (take! data s end 8)]
    (if s.ok
      (le.read-u64 data at)
      0)))

(define (read-string
  [data : (& b (__tl_dyn-array u8))]
  [at : i64]
  [count : i64]) : String
  (let
    [out : buf.ByteBufBuilder (buf.byte-buf-builder-with-capacity count)]
    (buf.byte-buf-builder-append-array-range (&mut out) data at count)
    (buf.byte-buf-builder-to-string (& out))))

(define (span-less?
  [data : (& b (__tl_dyn-array u8))]
  [a : i64]
  [an : i64]
  [b : i64]
  [bn : i64]) : bool
  (let
    [i : i64 0]
    (while (and (< i an) (< i bn))
      (let
        [x : u8 (array-ref data (+ a i))]
        [y : u8 (array-ref data (+ b i))]
        (when (< x y) (return true))
        (when (> x y) (return false)))
      (set! i (+ i 1)))
    (< an bn)))

(define (parse-node
  [data : (& b (__tl_dyn-array u8))]
  [s : (&mut s Scan)]
  [end : i64]
  [depth : i64]
  [build : bool]) : wire.Value
  (when (not s.ok) (return (wire.Null)))
  (when
    (> depth s.limits.max-depth)
    (fail! s (DepthLimit) s.offset)
    (return (wire.Null)))
  (when
    (>= s.nodes s.limits.max-nodes)
    (fail! s (NodeLimit) s.offset)
    (return (wire.Null)))
  (set! s.nodes (+ s.nodes 1))
  (charge! s 1 4096)
  (let
    [tag-at : i64 (take! data s end 1)]
    [tag : i64
      (if s.ok
        (cast (array-ref data tag-at) : i64)
        -1)]
    [length : i64 (u64! data s end)]
    [start : i64 s.offset]
    (when (not s.ok) (return (wire.Null)))
    (when
      (not (bytes.range-present? end start length))
      (fail! s (BadLength) tag-at)
      (return (wire.Null)))
    (let
      [stop : i64 (+ start length)]
      [result : wire.Value
        (match tag
          [0
            (when (!= length 0) (fail! s (BadLength) tag-at))
            (wire.Null)]
          [1
            (if (!= length 1)
              (begin
                (fail! s (BadLength) tag-at)
                (wire.Null))
              (let
                [at : i64 (take! data s stop 1)]
                [value : i64 (cast (array-ref data at) : i64)]
                (when (> value 1) (fail! s (BadBoolean) at))
                (wire.Boolean (= value 1))))]
          [2
            (if (!= length 8)
              (begin
                (fail! s (BadLength) tag-at)
                (wire.Null))
              (let
                [number : i64 (u64! data s stop)]
                (when (>= number 0) (fail! s (BadInteger) start))
                (wire.Signed number)))]
          [3
            (if (!= length 8)
              (begin
                (fail! s (BadLength) tag-at)
                (wire.Null))
              (wire.Unsigned (cast (u64! data s stop) : u64)))]
          [4
            (string-charge! s length)
            (take! data s stop length)
            (if (and build s.ok)
              (wire.ByteString (read-string data start length))
              (wire.Null))]
          [5
            (let
              [count : i64 (u32! data s stop)]
              (when
                (> count (- s.limits.max-nodes s.nodes))
                (fail! s (NodeLimit) start))
              (charge! s count (* count 64))
              (let
                [items : (__tl_dyn-array wire.Value)
                  (__tl_make-array
                    wire.Value
                    (if (and build s.ok)
                      count
                      0))]
                [i : i64 0]
                (while (and s.ok (< i count))
                  (let
                    [item : wire.Value
                      (parse-node data s stop (+ depth 1) build)]
                    (when build (set! (array-ref items i) item)))
                  (set! i (+ i 1)))
                (if build
                  (wire.Sequence (box (wire.ValueSeq items count)))
                  (wire.Null))))]
          [6
            (let
              [count : i64 (u32! data s stop)]
              (when
                (> count s.limits.max-record-fields)
                (fail! s (FieldLimit) start))
              (when
                (> count (- s.limits.max-nodes s.nodes))
                (fail! s (NodeLimit) start))
              (charge! s count (* count 96))
              (let
                [items : (__tl_dyn-array wire.Field)
                  (__tl_make-array
                    wire.Field
                    (if (and build s.ok)
                      count
                      0))]
                [i : i64 0]
                [previous-at : i64 0]
                [previous-length : i64 0]
                (while (and s.ok (< i count))
                  (let
                    [key-length : i64 (u32! data s stop)]
                    [key-at : i64 (take! data s stop key-length)]
                    (string-charge! s key-length)
                    (when
                      (and s.ok (> i 0))
                      (charge! s (+ previous-length key-length) 0)
                      (when
                        (and
                          s.ok
                          (not
                            (span-less?
                              data
                              previous-at
                              previous-length
                              key-at
                              key-length)))
                        (fail! s (BadKeyOrder) key-at)))
                    (set! previous-at key-at)
                    (set! previous-length key-length)
                    (let
                      [item : wire.Value
                        (parse-node data s stop (+ depth 1) build)]
                      (when
                        (and build s.ok)
                        (set!
                          (array-ref items i)
                          (wire.Field (read-string data key-at key-length) item)))))
                  (set! i (+ i 1)))
                (if build
                  (wire.Record (box (wire.FieldSeq items count)))
                  (wire.Null))))]
          [_
            (fail! s (BadTag) tag-at)
            (wire.Null)])]
      (when (and s.ok (!= s.offset stop)) (fail! s (TrailingBytes) s.offset))
      result)))

(define (kind-number [kind : DocumentKind]) : i64
  (match kind
    [(ManifestDocument) 1]
    [(ProfileDocument) 2]
    [(SemanticInputDocument) 3]))

(define (domain-byte [index : i64]) : u8
  (cast
    (match index
      [0 84]
      [1 76]
      [2 78]
      [3 65]
      [4 84]
      [5 73]
      [6 86]
      [7 69]
      [8 76]
      [9 73]
      [10 78]
      [_ 75])
    : u8))

(define (decode
  [data : (& b (__tl_dyn-array u8))]
  [kind : DocumentKind]
  [limits : (& l Limits)]) : DecodeResult
  (when
    (not (valid-limits? limits))
    (return (DecodeFailed (Error (InvalidLimit) 0))))
  (let
    [n : i64 (array-length data)]
    [s : Scan (new-scan limits)]
    (when (> n limits.max-bytes) (return (DecodeFailed (Error (ByteLimit) 0))))
    (when (< n 32) (return (DecodeFailed (Error (Truncated) n))))
    (for [i (iterator.range 0 12)]
      (when
        (!= (array-ref data i) (domain-byte i))
        (return (DecodeFailed (Error (BadDomain) i)))))
    (when
      (!= (le.read-u16 data 12) 1)
      (return (DecodeFailed (Error (BadVersion) 12))))
    (when
      (!= (le.read-u16 data 14) (kind-number kind))
      (return (DecodeFailed (Error (BadDocumentKind) 14))))
    (when
      (!= (le.read-u64 data 16) (- n 32))
      (return (DecodeFailed (Error (BadLength) 16))))
    (let
      [expected : i64 (le.read-u64 data 24)]
      (when
        (or (< expected 1) (> expected limits.max-nodes))
        (return (DecodeFailed (Error (NodeLimit) 24))))
      (set! s.offset 32)
      (parse-node data (&mut s) n 0 false)
      (when
        (and s.ok (!= s.offset n))
        (fail! (&mut s) (TrailingBytes) s.offset))
      (when (and s.ok (!= s.nodes expected)) (fail! (&mut s) (BadLength) 24))
      (when (not s.ok) (return (DecodeFailed s.error)))
      ;; Reserve the second pass's work before any input-sized construction.
      (charge! (&mut s) s.work 0)
      (when (not s.ok) (return (DecodeFailed s.error)))
      ;; The second pass has identical limits and immutable input. It constructs
      ;; only the tree whose full byte/element/depth/allocation budget passed.
      (let
        [build : Scan (new-scan limits)]
        (set! build.offset 32)
        (let
          [value : wire.Value (parse-node data (&mut build) n 0 true)]
          (if build.ok
            (Decoded value)
            (DecodeFailed build.error)))))))

(define (emit-byte!
  [out : (&mut b (__tl_dyn-array u8))]
  [s : (&mut s Scan)]
  [value : u8]
  [write : bool]) : unit
  (when
    s.ok
    (if (>= s.offset s.limits.max-bytes)
      (fail! s (ByteLimit) s.offset)
      (begin
        (when write (set! (array-ref out s.offset) value))
        (set! s.offset (+ s.offset 1))
        (charge! s 1 0)))))

(define (emit-integer!
  [out : (&mut b (__tl_dyn-array u8))]
  [s : (&mut s Scan)]
  [value : i64]
  [count : i64]
  [write : bool]) : unit
  (for [i (iterator.range 0 count)]
    (emit-byte! out s (le.byte-le-byte value (* i 8)) write)))

(define (emit-string!
  [out : (&mut b (__tl_dyn-array u8))]
  [s : (&mut s Scan)]
  [value : (& v str)]
  [write : bool]) : unit
  (let
    [n : i64 (string.string-length value)]
    [i : i64 0]
    (string-charge! s n)
    (while (and s.ok (< i n))
      (emit-byte! out s (cast (string.string-ref value i) : u8) write)
      (set! i (+ i 1)))))

(define (value-tag [value : (& v wire.Value)]) : i64
  (match value
    [(wire.Null) 0]
    [(wire.Boolean _) 1]
    [(wire.Signed _) 2]
    [(wire.Unsigned _) 3]
    [(wire.ByteString _) 4]
    [(wire.Sequence _) 5]
    [(wire.Record _) 6]))

(define (emit-node!
  [out : (&mut b (__tl_dyn-array u8))]
  [s : (&mut s Scan)]
  [value : (& v wire.Value)]
  [depth : i64]
  [write : bool]) : unit
  (when (not s.ok) (return unit))
  (when
    (> depth s.limits.max-depth)
    (fail! s (DepthLimit) s.offset)
    (return unit))
  (when
    (>= s.nodes s.limits.max-nodes)
    (fail! s (NodeLimit) s.offset)
    (return unit))
  (set! s.nodes (+ s.nodes 1))
  (charge! s 1 4096)
  (emit-byte! out s (cast (value-tag value) : u8) write)
  (let
    [size-at : i64 s.offset]
    (emit-integer! out s 0 8 write)
    (let
      [start : i64 s.offset]
      (match value
        [(wire.Null) unit]
        [(wire.Boolean found)
          (emit-byte!
            out
            s
            (cast
              (if found
                1
                0)
              : u8)
            write)]
        [(wire.Signed found)
          (when (>= found 0) (fail! s (BadInteger) start))
          (emit-integer! out s found 8 write)]
        [(wire.Unsigned found) (emit-integer! out s (cast found : i64) 8 write)]
        [(wire.ByteString found) (emit-string! out s found write)]
        [(wire.Sequence boxed)
          (let
            [n : i64 (deref boxed).len]
            (when
              (or
                (< n 0)
                (> n (array-length (& (deref boxed).slots)))
                (> n 4294967295))
              (fail! s (BadLength) start))
            (when
              (> n (- s.limits.max-nodes s.nodes))
              (fail! s (NodeLimit) start))
            (emit-integer! out s n 4 write)
            (let
              [i : i64 0]
              (while (and s.ok (< i n))
                (emit-node!
                  out
                  s
                  (& (array-ref (deref boxed).slots i))
                  (+ depth 1)
                  write)
                (set! i (+ i 1)))))]
        [(wire.Record boxed)
          (let
            [n : i64 (deref boxed).len]
            (when
              (or (< n 0) (> n (array-length (& (deref boxed).slots))))
              (fail! s (BadLength) start))
            (when (> n s.limits.max-record-fields) (fail! s (FieldLimit) start))
            (emit-integer! out s n 4 write)
            (let
              [i : i64 0]
              (while (and s.ok (< i n))
                (let
                  [key : (& v str) (& (array-ref (deref boxed).slots i).key)]
                  [length : i64 (string.string-length key)]
                  (when
                    (> i 0)
                    (charge!
                      s
                      (+
                        length
                        (string.string-length
                          (& (array-ref (deref boxed).slots (- i 1)).key)))
                      0)
                    (when
                      (and
                        s.ok
                        (not
                          (wire.key-less?
                            (& (array-ref (deref boxed).slots (- i 1)).key)
                            key)))
                      (fail! s (BadKeyOrder) s.offset)))
                  (when (> length 4294967295) (fail! s (BadLength) s.offset))
                  (emit-integer! out s length 4 write)
                  (emit-string! out s key write)
                  (emit-node!
                    out
                    s
                    (& (array-ref (deref boxed).slots i).value)
                    (+ depth 1)
                    write))
                (set! i (+ i 1)))))])
      (when (and s.ok write) (le.set-u64! out size-at (- s.offset start))))))

(define (encode
  [value : (& v wire.Value)]
  [kind : DocumentKind]
  [limits : (& l Limits)]) : EncodeResult
  (when
    (not (valid-limits? limits))
    (return (EncodeFailed (Error (InvalidLimit) 0))))
  (when (< limits.max-bytes 32) (return (EncodeFailed (Error (ByteLimit) 0))))
  (let
    [scan : Scan (new-scan limits)]
    [empty : (__tl_dyn-array u8) (__tl_make-array u8 0)]
    (set! scan.offset 32)
    (emit-node! (&mut empty) (&mut scan) value 0 false)
    (when (not scan.ok) (return (EncodeFailed scan.error)))
    ;; The dry traversal reserves the identical write traversal as well.
    (charge! (&mut scan) scan.work 0)
    (charge! (&mut scan) scan.offset scan.offset)
    (when (not scan.ok) (return (EncodeFailed scan.error)))
    (let
      [out : (__tl_dyn-array u8) (__tl_make-array u8 scan.offset)]
      [write : Scan (new-scan limits)]
      (for [i (iterator.range 0 12)]
        (set! (array-ref out i) (domain-byte i)))
      (le.set-u16! (&mut out) 12 1)
      (le.set-u16! (&mut out) 14 (kind-number kind))
      (le.set-u64! (&mut out) 16 (- scan.offset 32))
      (le.set-u64! (&mut out) 24 scan.nodes)
      (set! write.offset 32)
      (emit-node! (&mut out) (&mut write) value 0 true)
      (if write.ok
        (Encoded out)
        (EncodeFailed write.error)))))