;# benchmarks/intern_table/bench.tl - entry point for the interner benchmark.
(import intern_table_kernel as kernel)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)

(defmacro (it-owner-ref [items : Expr] [index : Expr]) : Expr
  `(kernel.it-i64-ref (& ,items) ,index))

(define (it-bench [path : String] [rounds : i64]) : i64
  (let
    [source : String (byte_buf.to-string (io.read-file path))]
    [text (kernel.it-string-to-u8-vec source)]
    [n : i64 (kernel.it-u8-len (& text))]
    [line-count : i64 (kernel.it-count-lines (& text) n)]
    [starts (kernel.it-zero-i64-vec (+ line-count 1))]
    [lengths (kernel.it-zero-i64-vec (+ line-count 1))]
    [lines : i64
      (kernel.it-index-lines (& text) n (&mut starts) (&mut lengths))]
    [storage-capacity : i64 (kernel.it-map-storage lines)]
    [map-ids (kernel.it-zero-i64-vec storage-capacity)]
    [map-hashes (kernel.it-zero-i64-vec storage-capacity)]
    [names (kernel.it-zero-u8-vec (+ n 1))]
    [name-off (kernel.it-zero-i64-vec (+ lines 1))]
    [name-len (kernel.it-zero-i64-vec (+ lines 1))]
    [state (kernel.it-zero-i64-vec 3)]
    [round : i64 0]
    [acc : i64 0]
    (begin
      (while (< round rounds)
        (begin
          (kernel.it-reset! (&mut map-ids) (&mut state))
          (let
            [pass : i64 0]
            [k : i64 0]
            (while (< pass 2)
              (begin
                (set! k 0)
                (while (< k lines)
                  (let
                    [id : i64
                      (kernel.it-intern-slice
                        (& text)
                        (it-owner-ref starts k)
                        (it-owner-ref lengths k)
                        (&mut map-ids)
                        (&mut map-hashes)
                        (&mut names)
                        (&mut name-off)
                        (&mut name-len)
                        (&mut state))]
                    (begin
                      (set! acc (+ (* acc 1000003) (* id 2654435761)))
                      (set! k (+ k 1)))))
                (set! pass (+ pass 1)))))
          (set! round (+ round 1))))
      (+ (* acc 1000003) (it-owner-ref state 1)))))

(define (main) : i64
  (let
    [path : String (io.arg 1)]
    [rounds : i64 (string.>int (io.arg 2))]
    (begin
      (io.print (it-bench path rounds))
      0)))