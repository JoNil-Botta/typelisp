;; Refs #9510: gep_offset must not hoist a derived base above its base.
;; The do-while keeps `j = start + i` in the loop, and its only use is the
;; `ptr-offset` Gep after the loop. In `exit-read` that Gep's base is made after
;; the loop, so the split must not happen; in `entry-read` the data pointer is
;; read before the loop, reaches the preheader, and the access still splits.
(import stdlib.io)

(define (fill [items : (&mut items (__tl_dyn-array i64))] [scale : i64]) : unit
  (let
    [k : i64 0]
    (while (< k 16)
      (set! (array-ref items k) (* k scale))
      (set! k (+ k 1)))))

(define (exit-read [n : i64] [start : i64]) : i64
  (let
    [i : i64 0]
    [j : i64 0]
    (while true
      (set! j (+ start i))
      (set! i (+ i 1))
      (when (>= i n) (break)))
    (let
      [items : (__tl_dyn-array i64) (__tl_make-array i64 16)]
      (fill (&mut items) 3)
      (unsafe
        (ptr-read (ptr-offset (ptr-cast (__tl_array-data items) : (Ptr i64)) j))))))

(define (entry-read [n : i64] [start : i64]) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 16)]
    [_ : unit (fill (&mut items) 4)]
    [data : (Ptr i64)
      (unsafe
        (ptr-cast (__tl_array-data items) : (Ptr i64)))]
    [i : i64 0]
    [j : i64 0]
    (while true
      (set! j (+ start i))
      (set! i (+ i 1))
      (when (>= i n) (break)))
    (unsafe
      (ptr-read (ptr-offset data j)))))

(define (main) : i64
  (let
    [argc : i64 (io.arg-count)]
    ;; argc = 1: n = 3, start = 4, so j = 6; 6 * 3 + 6 * 4 = 42
    (+ (exit-read (+ 2 argc) (+ 3 argc)) (entry-read (+ 2 argc) (+ 3 argc)))))