;; Independent test-only v1 reader: no production binary scanner, byte reader,
;; serializer framing or canonicalizer. Its small fixed budgets bound malformed
;; counts before allocation; tests also exercise production's configurable caps.
(import native_link_manifest_wire as wire)
(import stdlib.byte_buf_core as buf)
(import stdlib.string)
(import stdlib.iterator)

(defstruct OracleState
  (ok bool)
  (at i64)
  (nodes i64)
  (strings i64)
  (retained i64))

(defenum OracleResult
  (OracleValue wire.Value)
  (OracleRejected))

(define (take! [s : (&mut s OracleState)] [end : i64] [count : i64]) : i64
  (let
    [start : i64 s.at]
    (if (or (< count 0) (> start end) (> count (- end start)))
      (set! s.ok false)
      (set! s.at (+ start count)))
    start))

(define (number!
  [data : (& b (__tl_dyn-array u8))]
  [s : (&mut s OracleState)]
  [end : i64]
  [count : i64]) : u64
  (let
    [start : i64 (take! s end count)]
    [value : u64 (cast 0 : u64)]
    (when
      s.ok
      (for [i (iterator.range 0 count)]
        (set!
          value
          (bit-or value (shl (cast (array-ref data (+ start i)) : u64) (* i 8))))))
    value))

(define (retain! [s : (&mut s OracleState)] [amount : i64]) : unit
  (if (or (< amount 0) (> amount (- 67108864 s.retained)))
    (set! s.ok false)
    (set! s.retained (+ s.retained amount))))

(define (text!
  [data : (& b (__tl_dyn-array u8))]
  [s : (&mut s OracleState)]
  [end : i64]
  [count : i64]) : String
  (let
    [start : i64 (take! s end count)]
    (when (or (> count (- 524288 s.strings)) (< count 0)) (set! s.ok false))
    (when (not s.ok) (return ""))
    (set! s.strings (+ s.strings count))
    (retain! s (* count 4))
    (when (not s.ok) (return ""))
    (let
      [bytes : buf.ByteBufBuilder (buf.byte-buf-builder-with-capacity count)]
      (for [i (iterator.range 0 count)]
        (buf.byte-buf-builder-push (&mut bytes) (array-ref data (+ start i))))
      (buf.byte-buf-builder-to-string (& bytes)))))

(define (less? [a : (& a str)] [b : (& b str)]) : bool
  (let
    [i : i64 0]
    [an : i64 (string.string-length a)]
    [bn : i64 (string.string-length b)]
    (while (and (< i an) (< i bn))
      (let
        [x : i64 (cast (string.string-ref a i) : i64)]
        [y : i64 (cast (string.string-ref b i) : i64)]
        (when (!= x y) (return (< x y))))
      (set! i (+ i 1)))
    (< an bn)))

(define (node!
  [data : (& b (__tl_dyn-array u8))]
  [s : (&mut s OracleState)]
  [end : i64]
  [depth : i64]) : wire.Value
  (when
    (or (not s.ok) (> depth 48) (>= s.nodes 16384))
    (set! s.ok false)
    (return (wire.Null)))
  (set! s.nodes (+ s.nodes 1))
  (retain! s 256)
  (let
    [tag : u64 (number! data s end 1)]
    [size : u64 (number! data s end 8)]
    (when
      (or (not s.ok) (> size (cast (- end s.at) : u64)))
      (set! s.ok false)
      (return (wire.Null)))
    (let
      [limit : i64 (+ s.at (cast size : i64))]
      [value : wire.Value
        (cond
          [(= tag (cast 0 : u64)) (wire.Null)]
          [(= tag (cast 1 : u64))
            (let
              [b : u64 (number! data s limit 1)]
              (when (> b (cast 1 : u64)) (set! s.ok false))
              (wire.Boolean (= b (cast 1 : u64))))]
          [(= tag (cast 2 : u64))
            (let
              [value : i64 (cast (number! data s limit 8) : i64)]
              (when (>= value 0) (set! s.ok false))
              (wire.Signed value))]
          [(= tag (cast 3 : u64)) (wire.Unsigned (number! data s limit 8))]
          [(= tag (cast 4 : u64))
            (wire.ByteString (text! data s limit (cast size : i64)))]
          [(= tag (cast 5 : u64))
            (let
              [count : u64 (number! data s limit 4)]
              (when
                (or
                  (not s.ok)
                  (> count (cast 4096 : u64))
                  (> count (cast (/ (- limit s.at) 9) : u64)))
                (set! s.ok false)
                (return (wire.Null)))
              (retain! s (* (cast count : i64) 256))
              (when (not s.ok) (return (wire.Null)))
              (let
                [n : i64 (cast count : i64)]
                [slots : (__tl_dyn-array wire.Value)
                  (__tl_make-array wire.Value n)]
                [i : i64 0]
                (while (and s.ok (< i n))
                  (set! (array-ref slots i) (node! data s limit (+ depth 1)))
                  (set! i (+ i 1)))
                (wire.Sequence (box (wire.ValueSeq slots n)))))]
          [(= tag (cast 6 : u64))
            (let
              [count : u64 (number! data s limit 4)]
              (when
                (or
                  (not s.ok)
                  (> count (cast 64 : u64))
                  (> count (cast (/ (- limit s.at) 13) : u64)))
                (set! s.ok false)
                (return (wire.Null)))
              (retain! s (* (cast count : i64) 512))
              (when (not s.ok) (return (wire.Null)))
              (let
                [n : i64 (cast count : i64)]
                [slots : (__tl_dyn-array wire.Field)
                  (__tl_make-array wire.Field n)]
                [i : i64 0]
                (while (and s.ok (< i n))
                  (let
                    [length : u64 (number! data s limit 4)]
                    (when
                      (> length (cast (- limit s.at) : u64))
                      (set! s.ok false)
                      (return (wire.Null)))
                    (let
                      [key : String (text! data s limit (cast length : i64))]
                      (when
                        (and
                          (> i 0)
                          (not
                            (less? (& (array-ref slots (- i 1)).key) (& key))))
                        (set! s.ok false))
                      (set!
                        (array-ref slots i)
                        (wire.Field key (node! data s limit (+ depth 1))))))
                  (set! i (+ i 1)))
                (wire.Record (box (wire.FieldSeq slots n)))))]
          [else
            (set! s.ok false)
            (wire.Null)])]
      (when (!= s.at limit) (set! s.ok false))
      value)))

(define (decode [data : (& b (__tl_dyn-array u8))]) : OracleResult
  (let
    [length : i64 (array-length data)]
    [s : OracleState (OracleState true 0 0 0 0)]
    (when (or (< length 32) (> length 2097152)) (return (OracleRejected)))
    (let
      [magic : String "TLNATIVELINK"]
      (for [i (iterator.range 0 12)]
        (when
          (!= (array-ref data i) (cast (string.string-ref (& magic) i) : u8))
          (return (OracleRejected)))))
    (set! s.at 12)
    (when
      (!= (number! data (&mut s) length 2) (cast 1 : u64))
      (return (OracleRejected)))
    (when
      (!= (number! data (&mut s) length 2) (cast 3 : u64))
      (return (OracleRejected)))
    (when
      (!= (number! data (&mut s) length 8) (cast (- length 32) : u64))
      (return (OracleRejected)))
    (let
      [nodes : u64 (number! data (&mut s) length 8)]
      [value : wire.Value (node! data (&mut s) length 0)]
      (if (and s.ok (= s.at length) (= nodes (cast s.nodes : u64)))
        (OracleValue value)
        (OracleRejected)))))