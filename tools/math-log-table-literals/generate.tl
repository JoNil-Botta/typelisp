;; Emit the stdlib.math log-table payloads as shortest round-tripping f64
;; literals.  The fixed table/field walk makes the output a migration manifest:
;; running it before and after a literal rewrite must be byte-identical.
(import stdlib.array)
(import stdlib.io)
(import stdlib.math)
(import stdlib.string)

(define (math-log-literal-seen?
  [seen : (__tl_dyn-array u64)]
  [count : i64]
  [bits : u64]) : bool
  (let
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< index count))
        (if (= (array-ref seen index) bits)
          (set! found true)
          (set! index (+ index 1))))
      found)))

(define (math-log-literal-record!
  [seen : (__tl_dyn-array u64)]
  [index : i64]
  [bits : u64]) : bool
  (if (math-log-literal-seen? seen index bits)
    false
    (let
      [formatted : String (io.format-float-core (math.f64-from-bits bits))]
      ;; Integer-looking formatter results need a decimal point to remain f64
      ;; source literals at the call site.
      [text : String
        (if (string.eq formatted "0")
          "0.0"
          (if (string.eq formatted "1")
            "1.0"
            formatted))]
      (match (io.float-parse-f64 text)
        [(io.IoFloatSomeF64 parsed)
          (if (= (math.f64-to-bits parsed) bits)
            (begin
              (array-set! seen index bits)
              (io.print-string text)
              (io.print-string "\n")
              true)
            false)]
        [(io.IoFloatNoF64) false]))))

(define (math-log-literal-record-four!
  [seen : (__tl_dyn-array u64)]
  [index : i64]
  [a : u64]
  [b : u64]
  [c : u64]
  [d : u64]) : bool
  (and
    (math-log-literal-record! seen index a)
    (math-log-literal-record! seen (+ index 1) b)
    (math-log-literal-record! seen (+ index 2) c)
    (math-log-literal-record! seen (+ index 3) d)))

(define (math-log-literal-record-two!
  [seen : (__tl_dyn-array u64)]
  [index : i64]
  [a : u64]
  [b : u64]) : bool
  (and
    (math-log-literal-record! seen index a)
    (math-log-literal-record! seen (+ index 1) b)))

(define (main) : i64
  (let
    [seen : (__tl_dyn-array u64) (array.make-array u64 544)]
    [count : i64 0]
    [table-index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< table-index 128))
        (let
          [entry : math.MathLogF64TableEntry
            (math.math-log-f64-table-entry table-index)]
          (begin
            (set!
              ok
              (math-log-literal-record-four!
                seen
                count
                (struct-get entry invc-bits)
                (struct-get entry logc-bits)
                (struct-get entry chi-bits)
                (struct-get entry clo-bits)))
            (set! count (+ count 4))
            (set! table-index (+ table-index 1)))))
      (set! table-index 0)
      (while (and ok (< table-index 16))
        (let
          [entry : math.MathLogF32TableEntry
            (math.math-log-f32-table-entry table-index)]
          (begin
            (set!
              ok
              (math-log-literal-record-two!
                seen
                count
                (struct-get entry invc-bits)
                (struct-get entry logc-bits)))
            (set! count (+ count 2))
            (set! table-index (+ table-index 1)))))
      (if (and ok (= count 544))
        0
        1))))