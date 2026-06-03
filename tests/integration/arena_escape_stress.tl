; #1691: stress the manual scratch-arena escape pattern used by
; tc-check-decl-escaping, lower-function-escaping, optimize-function-escaping,
; and compiler-backend-emit-function-escaping until the high-level escape form
; is used everywhere.
;
; Each escape switches to a scratch arena, allocates past the 64 MiB arena
; granule so the scratch grows an overflow arena, clones the result back into
; the enclosing arena, rewinds or destroys the grown scratch head, and then
; reads the clone after later scratch cycles. RSS/peak-memory assertion is left
; manual because host reporting differs across CI platforms; stale handles fail
; as output/exit mismatches here.
(extern tl_alloc : (-> u64 u64))

(defenum StressList
  (StressNil)
  (StressCons String StressList))

(define (overflow-bytes) : u64
  (cast 67108864 : u64))

(define (force-overflow) : unit
  (begin
    (tl_alloc (overflow-bytes))
    unit))

(define (payload [seed : i64] [idx : i64]) : String
  (string-append
    (string-append "arena-stress:" (int->string seed))
    (string-append ":" (int->string idx))))

(define (make-list [count : i64] [seed : i64]) : StressList
  (if (= count 0)
    (StressNil)
    (StressCons (payload seed count) (make-list (- count 1) seed))))

(define (list-ok? [items : StressList] [count : i64] [seed : i64]) : bool
  (match items
    [(StressNil) (= count 0)]
    [(StressCons head rest)
      (and
        (> count 0)
        (and
          (string-eq head (payload seed count))
          (list-ok? rest (- count 1) seed)))]))

(define (escape-string [seed : i64]) : String
  (let
    [enclosing : i64 (arena-current)]
    (let
      [scratch : i64 (arena-make)]
      (begin
        (arena-set! scratch)
        (let
          [raw : String (payload seed 999)]
          (begin
            (force-overflow)
            (let
              [scratch-head : i64 (arena-current)]
              (begin
                (arena-set! enclosing)
                (let
                  [escaped : String (clone raw)]
                  (begin
                    (arena-destroy scratch-head)
                    escaped))))))))))

(define (escape-list [count : i64] [seed : i64]) : StressList
  (let
    [enclosing : i64 (arena-current)]
    (let
      [scratch : i64 (arena-make)]
      (begin
        (arena-set! scratch)
        (let
          [raw : StressList (make-list count seed)]
          (begin
            (force-overflow)
            (let
              [scratch-head : i64 (arena-current)]
              (begin
                (arena-set! enclosing)
                (let
                  [escaped : StressList (clone raw)]
                  (begin
                    (arena-destroy scratch-head)
                    escaped))))))))))

(define (escape-list-rewind [scratch : i64] [count : i64] [seed : i64]) : StressList
  (let
    [enclosing : i64 (arena-current)]
    (begin
      (arena-set! scratch)
      (let
        [mark : i64 (arena-mark)]
        (let
          [raw : StressList (make-list count seed)]
          (begin
            (force-overflow)
            (let
              [scratch-head : i64 (arena-current)]
              (begin
                (arena-set! enclosing)
                (let
                  [escaped : StressList (clone raw)]
                  (let
                    [new-enclosing : i64 (arena-current)]
                    (begin
                      (arena-set! scratch-head)
                      (arena-rewind mark)
                      (arena-set! new-enclosing)
                      escaped)))))))))))

(define (string-cycles [n : i64] [acc : i64]) : i64
  (if (= n 0)
    acc
    (let
      [escaped : String (escape-string n)]
      [noise : StressList (escape-list 8 (+ n 1000))]
      (if (and
        (string-eq escaped (payload n 999))
        (list-ok? noise 8 (+ n 1000)))
        (string-cycles (- n 1) (+ acc (string-length escaped)))
        0))))

(define (list-cycles [n : i64] [acc : i64]) : i64
  (if (= n 0)
    acc
    (let
      [items : StressList (escape-list 96 n)]
      [after : String (escape-string (+ n 2000))]
      (if (and (list-ok? items 96 n) (string-eq after (payload (+ n 2000) 999)))
        (list-cycles (- n 1) (+ acc 1))
        0))))

(define (rewind-list-cycles-inner [scratch : i64] [n : i64] [acc : i64]) : i64
  (if (= n 0)
    acc
    (let
      [items : StressList (escape-list-rewind scratch 96 n)]
      [after : StressList (escape-list-rewind scratch 8 (+ n 3000))]
      (if (and (list-ok? after 8 (+ n 3000)) (list-ok? items 96 n))
        (rewind-list-cycles-inner scratch (- n 1) (+ acc 1))
        0))))

(define (rewind-list-cycles [n : i64]) : i64
  (let
    [scratch : i64 (arena-make)]
    (let
      [score : i64 (rewind-list-cycles-inner scratch n 0)]
      (begin
        (arena-destroy scratch)
        score))))

(define (main) : i64
  (let
    [string-score : i64 (string-cycles 12 0)]
    [list-score : i64 (list-cycles 8 0)]
    [rewind-score : i64 (rewind-list-cycles 8)]
    (if (> string-score 0)
      (if (= list-score 8)
        (if (= rewind-score 8)
          42
          3)
        2)
      1)))
