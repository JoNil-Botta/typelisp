;; bce_call_carrying_trap.tl - trap parity THROUGH a cloned call.
;;
;; The multi-block bounds-check versioner now duplicates a direct call into its
;; fast clone. A trap raised INSIDE that callee has to report identically
;; whichever copy of the call site reached it: the abort names the callee's own
;; failing index, and the clone changed nothing about the callee.
;;
;; Both walkers below hand `bump` a `marks` array shorter than their window, so
;; `bump` aborts on its own `array-ref` the moment the window passes the end.
;; They differ only in which path gets there:
;;
;;   arg 0  `walk-fast` derives THREE checks against its one duplicated call
;;          site, clears opt-bce-mb-call-clone-min-derived, and versions -- the
;;          guard holds for this window, so the abort is raised from the CLONED
;;          call.
;;   arg 1  `walk-slow` is the same loop with one array fewer: two derived
;;          checks do not pay for a duplicated call, the versioner refuses it
;;          outright, and the abort is raised from the ORIGINAL call.
;;
;; The manifest pins both stderr messages, and they are the same message.
(import stdlib.io)
(import stdlib.string)

;; Element-clean and above every static inline band, so the call site survives
;; to be cloned. Its own `array-ref` is what aborts.
(define (bump
  [marks : (&mut marks (__tl_dyn-array i64))]
  [start : i64]
  [count : i64]
  [v : i64]) : i64
  (let
    [i : i64 start]
    [stop : i64 (+ start count)]
    [last : i64 0]
    [spin : i64 0]
    [guard : i64 0]
    (begin
      (while (< i stop)
        (begin
          (set! (array-ref marks i) (+ (array-ref marks i) v))
          (set! last (array-ref marks i))
          (set! i (+ i 1))))
      (set! i start)
      (while (< i stop)
        (begin
          (set! spin (+ spin (array-ref marks i)))
          (set! (array-ref marks i) (array-ref marks i))
          (set! i (+ i 1))))
      (set! i start)
      (while (< i stop)
        (begin
          (set! guard (+ guard (- (array-ref marks i) (array-ref marks i))))
          (set! (array-ref marks i) (+ (array-ref marks i) guard))
          (set! i (+ i 1))))
      (+ last guard))))

(define (walk-fast
  [items : (& items (__tl_dyn-array i64))]
  [other : (& other (__tl_dyn-array i64))]
  [extra : (& extra (__tl_dyn-array i64))]
  [marks : (&mut marks (__tl_dyn-array i64))]
  [n : i64]
  [seed : i64]) : i64
  (let
    [acc : i64 seed]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (array-ref items i)))
          (set! acc (+ acc (array-ref other i)))
          (if (> (array-ref extra i) 0)
            (set! acc (+ acc (bump (&mut marks) i 1 1)))
            (set! acc (- acc 1)))
          (set! i (+ i 1))))
      acc)))

(define (walk-slow
  [items : (& items (__tl_dyn-array i64))]
  [other : (& other (__tl_dyn-array i64))]
  [marks : (&mut marks (__tl_dyn-array i64))]
  [n : i64]
  [seed : i64]) : i64
  (let
    [acc : i64 seed]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (array-ref items i)))
          (if (> (array-ref other i) 0)
            (set! acc (+ acc (bump (&mut marks) i 1 1)))
            (set! acc (- acc 1)))
          (set! i (+ i 1))))
      acc)))

(define (fill [a : (&mut a (__tl_dyn-array i64))] [n : i64] [v : i64]) : unit
  (let
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! (array-ref a i) v)
          (set! i (+ i 1))))
      unit)))

(define (main) : i64
  (let
    [pick : i64 (string.>int (io.arg 1))]
    [len : i64 (+ 8 (io.arg-count))]
    [items (__tl_make-array i64 len)]
    [other (__tl_make-array i64 len)]
    [extra (__tl_make-array i64 len)]
    [marks (__tl_make-array i64 4)]
    (begin
      (fill (&mut items) len 2)
      (fill (&mut other) len 3)
      (fill (&mut extra) len 1)
      (if (= pick 0)
        (walk-fast (& items) (& other) (& extra) (&mut marks) len 7)
        (walk-slow (& items) (& other) (&mut marks) len 7)))))