;; Pushing onto the elements of an array of arrays. opt2's scratch reset once
;; freed every fresh element array at the end of the loop that stored it into
;; the outer array, so the pushes below reused freed descriptors and each
;; length read returned pushed data.
(define (predecessors [targets : (& targets (__tl_dyn-array i64))]) : (__tl_dyn-array
    (__tl_dyn-array i64))
  (let
    [blocks : i64 (array-length targets)]
    [out : (__tl_dyn-array (__tl_dyn-array i64))
      (__tl_make-array (__tl_dyn-array i64) blocks)]
    [block : i64 0]
    (while (< block blocks)
      (set! (array-ref out block) (__tl_make-array i64 0))
      (set! block (+ block 1)))
    (set! block 0)
    (while (< block blocks)
      (let
        [next : i64 (array-ref targets block)]
        (when
          (and (>= next 0) (< next blocks))
          (__tl_array-push! (array-ref out next) block))
        (when
          (< (+ block 1) blocks)
          (__tl_array-push! (array-ref out (+ block 1)) block)))
      (set! block (+ block 1)))
    out))

(define (main) : i64
  (let
    [targets : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    (set! (array-ref targets 0) 2)
    (set! (array-ref targets 1) -1)
    (set! (array-ref targets 2) 0)
    (set! (array-ref targets 3) -1)
    (let
      [preds : (__tl_dyn-array (__tl_dyn-array i64)) (predecessors (& targets))]
      [defaults : (__tl_dyn-array (__tl_dyn-array i64))
        (__tl_make-array (__tl_dyn-array i64) 2)]
      (__tl_array-push! (array-ref defaults 0) 5)
      (__tl_array-push! (array-ref defaults 1) 6)
      (__tl_array-push! (array-ref defaults 1) 7)
      ;; preds: 0 <- {2}, 1 <- {0}, 2 <- {0, 1}, 3 <- {2}
      (if (and
        (= (array-length (array-ref preds 0)) 1)
        (= (array-ref (array-ref preds 0) 0) 2)
        (= (array-length (array-ref preds 1)) 1)
        (= (array-length (array-ref preds 2)) 2)
        (= (array-ref (array-ref preds 2) 1) 1)
        (= (array-length (array-ref preds 3)) 1)
        (= (array-length (array-ref defaults 0)) 1)
        (= (array-length (array-ref defaults 1)) 2)
        (= (array-ref (array-ref defaults 1) 1) 7))
        42
        1))))