(import stdlib.profile)

(cfg
  compiler-arena-debug
  (unsafe
    (extern (debug-layout [owner : i64]) : unit (:symbol "tl_arena_debug_assert_pool_install"))))

(define values : (Array i64 2)
  (array 10 20))

(define (replace [seed : i64]) : unit
  (with-scratch (set! values (array seed (+ seed 1)))))

;; The 256th sixteen-byte container exactly fills the private static page.
;; The next replacement grows it while a receiver still points into that page.
(define (main) : i64
  (cfg
    compiler-arena-debug
    (unsafe
      (debug-layout 0)))
  (let
    [before : i64 (profile.alloc-total)]
    [i : i64 0]
    (while (< i 258)
      (set!
        (array-ref values 0)
        (begin
          (replace i)
          -1))
      (when
        (not (and (= (array-ref values 0) i) (= (array-ref values 1) (+ i 1))))
        (return 1))
      (+= i 1))
    (when (not (= (- (profile.alloc-total) before) (* 258 16))) (return 2)))
  42)