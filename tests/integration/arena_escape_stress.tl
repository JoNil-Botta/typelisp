; #1691: stress the manual scratch-arena escape pattern used by
; direct declaration checking, lower-function-escaping,
; optimize-function-escaping, and compiler-backend-emit-function-escaping
; until the high-level escape form is used everywhere.
;
; Each escape switches to a scratch arena, allocates past the 64 MiB arena
; granule so the scratch grows an overflow arena, clones the result back into
; the enclosing arena, rewinds or destroys the grown scratch head, and then
; reads the clone after later scratch cycles. RSS/peak-memory assertion is left
; manual because host reporting differs across CI platforms; stale handles fail
; as output/exit mismatches here.
(import stdlib.arena)
(import stdlib.array)
(import stdlib.string)

(extern (tl_alloc [arg0 : u64]) : u64)

(define (overflow-bytes) : u64
  (cast 67108864 : u64))

(define (force-overflow) : unit
  (begin
    (tl_alloc (overflow-bytes))
    unit))

(define (payload [seed : i64] [idx : i64]) : String
  (string.append
    (string.append "arena-stress:" (string.int->string seed))
    (string.append ":" (string.int->string idx))))

(define (fill-items
  [items : (__tl_dyn-array String)]
  [index : i64]
  [count : i64]
  [seed : i64]) : unit
  (if (= index count)
    unit
    (begin
      (array-set! items index (payload seed (- count index)))
      (fill-items items (+ index 1) count seed))))

(define (make-items [count : i64] [seed : i64]) : (__tl_dyn-array String)
  (let
    [items : (__tl_dyn-array String) (array.make-array String count)]
    (begin
      (fill-items items 0 count seed)
      items)))

(define (items-ok-from?
  [items : (__tl_dyn-array String)]
  [index : i64]
  [count : i64]
  [seed : i64]) : bool
  (if (= index count)
    true
    (and
      (string.eq (array-ref items index) (payload seed (- count index)))
      (items-ok-from? items (+ index 1) count seed))))

(define (items-ok? [items : (__tl_dyn-array String)] [count : i64] [seed : i64]) : bool
  (and (= (array-length items) count) (items-ok-from? items 0 count seed)))

(define (escape-string [seed : i64]) : String
  (let
    [enclosing : arena.Arena (arena.current)]
    [scratch : arena.Arena (arena.make)]
    (begin
      (unsafe
        (arena.set! scratch))
      (let
        [raw : String (payload seed 999)]
        (begin
          (force-overflow)
          (let
            [scratch-head : arena.Arena (arena.current)]
            (begin
              (unsafe
                (arena.set! enclosing))
              (let
                [escaped : String (clone raw)]
                (begin
                  (unsafe
                    (arena.destroy scratch-head))
                  escaped)))))))))

(define (escape-items [count : i64] [seed : i64]) : (__tl_dyn-array String)
  (let
    [enclosing : arena.Arena (arena.current)]
    [scratch : arena.Arena (arena.make)]
    (begin
      (unsafe
        (arena.set! scratch))
      (let
        [raw : (__tl_dyn-array String) (make-items count seed)]
        (begin
          (force-overflow)
          (let
            [scratch-head : arena.Arena (arena.current)]
            (begin
              (unsafe
                (arena.set! enclosing))
              (let
                [escaped : (__tl_dyn-array String) (clone raw)]
                (begin
                  (unsafe
                    (arena.destroy scratch-head))
                  escaped)))))))))

(define (escape-items-rewind [scratch : arena.Arena] [count : i64] [seed : i64]) : (__tl_dyn-array
    String)
  (let
    [enclosing : arena.Arena (arena.current)]
    (begin
      (unsafe
        (arena.set! scratch))
      (let
        [mark : arena.ArenaMark (arena.mark)]
        [raw : (__tl_dyn-array String) (make-items count seed)]
        (begin
          (force-overflow)
          (let
            [scratch-head : arena.Arena (arena.current)]
            (begin
              (unsafe
                (arena.set! enclosing))
              (let
                [escaped : (__tl_dyn-array String) (clone raw)]
                [new-enclosing : arena.Arena (arena.current)]
                (begin
                  (unsafe
                    (arena.set! scratch-head)
                    (arena.rewind mark)
                    (arena.set! new-enclosing))
                  escaped)))))))))

(define (string-cycles [n : i64] [acc : i64]) : i64
  (if (= n 0)
    acc
    (let
      [escaped : String (escape-string n)]
      [noise : (__tl_dyn-array String) (escape-items 8 (+ n 1000))]
      (if (and
        (string.eq escaped (payload n 999))
        (items-ok? noise 8 (+ n 1000)))
        (string-cycles (- n 1) (+ acc (string-length escaped)))
        0))))

(define (item-cycles [n : i64] [acc : i64]) : i64
  (if (= n 0)
    acc
    (let
      [items : (__tl_dyn-array String) (escape-items 96 n)]
      [after : String (escape-string (+ n 2000))]
      (if (and
        (items-ok? items 96 n)
        (string.eq after (payload (+ n 2000) 999)))
        (item-cycles (- n 1) (+ acc 1))
        0))))

(define (rewind-item-cycles-inner [scratch : arena.Arena] [n : i64] [acc : i64]) : i64
  (if (= n 0)
    acc
    (let
      [items : (__tl_dyn-array String) (escape-items-rewind scratch 96 n)]
      [after : (__tl_dyn-array String) (escape-items-rewind scratch 8 (+ n 3000))]
      (if (and (items-ok? after 8 (+ n 3000)) (items-ok? items 96 n))
        (rewind-item-cycles-inner scratch (- n 1) (+ acc 1))
        0))))

(define (rewind-item-cycles [n : i64]) : i64
  (let
    [scratch : arena.Arena (arena.make)]
    [score : i64 (rewind-item-cycles-inner scratch n 0)]
    (begin
      (unsafe
        (arena.destroy scratch))
      score)))

(define (main) : i64
  (let
    [string-score : i64 (string-cycles 3 0)]
    [item-score : i64 (item-cycles 3 0)]
    [rewind-score : i64 (rewind-item-cycles 3)]
    (begin
      (unless (> string-score 0) (return 1))
      (unless (= item-score 3) (return 2))
      (unless (= rewind-score 3) (return 3))
      42)))