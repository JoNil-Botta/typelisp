;; TRAP PARITY for MULTI-EXIT loop rotation.
;;
;; Rotation moves the loop's entry test out of the header and into the
;; preheader, and duplicates it onto the latch. That changes WHERE the first
;; iteration's work sits relative to the loop entry, and a multi-exit loop
;; changes it twice over: the second exit's gate stays in the body while the
;; counter test migrates to the latch, so the order in which the two tests and
;; the body's aborting access are reached on the FIRST trip is exactly what the
;; rewrite rearranges.
;;
;; `scan-row` walks `xs` under `(and (< i n) (not hit))` -- the multi-exit
;; shape -- and indexes a SHORT array `ys` with the same counter. `n` is 8 and
;; `ys` holds 4, so the fourth iteration aborts inside `ys`'s bounds check. The
;; sentinel is absent, so the escape door is never taken and the abort is the
;; only way out.
;;
;; A rotation that reorders the abort against the loop entry would move the
;; abort earlier (before the line printed ahead of the loop) or later (after
;; more iterations), or make it name a different index. This fixture pins all
;; three: the line printed before the loop must survive on stdout, and the
;; abort must name index 4 against length 4 at this source position.
(import stdlib.io)

(define (scan-row
  [xs : (Array i64)]
  [ys : (Array i64)]
  [n : i64]
  [sentinel : i64]) : i64
  (let
    [i : i64 0]
    [hit : bool false]
    [acc : i64 0]
    (begin
      (while (and (< i n) (not hit))
        (begin
          (set! acc (+ acc (array-ref ys i)))
          (if (= (array-ref xs i) sentinel)
            (set! hit true)
            (set! i (+ i 1)))))
      (+ acc i))))

(define (main) : i64
  (let
    [xs : (Array i64) (make-array i64 8)]
    [ys : (Array i64) (make-array i64 4)]
    [i : i64 0]
    (begin
      (while (< i 8)
        (begin
          (set! (array-ref xs i) (* i 3))
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i 4)
        (begin
          (set! (array-ref ys i) 1)
          (set! i (+ i 1))))
      (io.println "rows")
      (io.print (scan-row xs ys 8 -1))
      42)))