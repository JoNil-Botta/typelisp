;; The negative twin of checked_cheap_tier_claim (ABT-1): the SAME two-tier
;; program with a checked load added to it, run so that the check which fires is
;; inside a body an inliner copied.
;;
;; The claim's point is that two DIFFERENT tiers copy a body into `probe`, and
;; both copies come along here:
;;
;;   * `mix` is the four-site tiny leaf the cheap, unmeasured bands take for
;;     free, and `lane` -- one `array-ref`, call-free -- rides the same bands
;;     from a site inside `probe`'s loop;
;;   * `hash-words` is the intern kernel's shape, a cyclic call-free
;;     bounds-carrying word loop called ONCE from `probe`'s ENTRY block, which
;;     only the measured tier's re-plan can take.
;;
;; So the two manifest rows trap through the two tiers' copies -- `8 0` inside
;; the body the MEASURED tier claimed, `32 20` inside the one the CHEAP band
;; took -- and both must name the load in the CALLEE, the line and column inside
;; `hash-words` or inside `lane` and not the call in `probe`, with the index and
;; the length: byte for byte the message that body prints when it stays out of
;; line. The array is sized from argv so nothing can fold the run away, while
;; `probe`'s own window stays the constant the positive twin uses, so both tiers
;; make exactly the copies they make there.
(import stdlib.io)
(import stdlib.string)

;; The cheap tier's leaves: the claim fixture's arithmetic one, and a
;; single-load checked one at three of the same kind of site.
(define (mix [a : i64] [b : i64]) : i64
  (bit-xor (+ (* a 3) b) (* b 5)))

(define (lane [data : (& d (__tl_dyn-array i64))] [i : i64]) : i64
  (array-ref data i))

;; The measured tier's body: a cyclic, call-free, bounds-carrying word loop.
(define (hash-words
  [data : (& d (__tl_dyn-array i64))]
  [start : i64]
  [len : i64]) : i64
  (let
    [h : i64 2166136261]
    [i : i64 start]
    (begin
      (while (< i (+ start len))
        (begin
          (set! h (bit-xor h (array-ref data i)))
          (set! h (* h 16777619))
          (set! i (+ i 1))))
      h)))

;; The hot caller: the hash at its entry, then a loop of its own holding two of
;; `mix`'s four sites and one of `lane`'s three.
(define (probe
  [data : (& d (__tl_dyn-array i64))]
  [start : i64]
  [len : i64]
  [bias : i64]) : i64
  (let
    [h : i64 (hash-words data start len)]
    [acc : i64 0]
    [i : i64 0]
    (begin
      (while (< i len)
        (begin
          (set! acc (+ acc (bit-and (mix h i) 1023)))
          (set! acc (+ acc (bit-and (mix i h) 511)))
          (set! acc (+ acc (bit-and (lane data (+ i bias)) 255)))
          (set! h (+ h 7))
          (set! i (+ i 1))))
      acc)))

;; A cold second reference to the hash and to the caller, so no single-reference
;; band can claim either before the measured tier is asked; a site of each leaf
;; rides along.
(define (checksum [data : (& d (__tl_dyn-array i64))] [len : i64]) : i64
  (+
    (bit-and (mix (lane data 0) (hash-words data 0 len)) 65535)
    (probe data 0 4 0)))

(define (main) : i64
  (let
    [size : i64 (string.>int (io.arg 1))]
    [bias : i64 (string.>int (io.arg 2))]
    [data : (__tl_dyn-array i64) (__tl_make-array i64 size)]
    [i : i64 0]
    [total : i64 0]
    [cold : i64 0]
    (begin
      (while (< i size)
        (begin
          (set! (array-ref data i) (* (+ i 1) 2654435761))
          (set! i (+ i 1))))
      ;; `probe`'s own shape is the claim fixture's, constant window and all, so
      ;; the two tiers make the same two copies; only the ARRAY is sized from
      ;; argv. A `size` under the window walks the hash loop off the end inside
      ;; the body the measured tier copied, and a `bias` past the tail walks the
      ;; leaf's load off the end inside the body the cheap tier copied.
      (set! i 0)
      (while (< i 64)
        (begin
          (set! total (+ total (probe (& data) 0 16 bias)))
          (set! i (+ i 1))))
      ;; Never reached, and there for the same reason as in the positive twin:
      ;; the cold references keep both callees off every single-site band.
      (set! cold (+ cold (checksum (& data) 8)))
      (unless (= total 0) (return 1))
      (unless (= cold 0) (return 2))
      (unless (= (mix total 3) 0) (return 3))
      42)))