(import stdlib.profile)

(cfg
  compiler-arena-debug
  (unsafe
    (extern (debug-layout [owner : i64]) : unit (:symbol "tl_arena_debug_assert_pool_install"))))

(define values : (Array i64 2)
  (array 10 20))

(define (replace [seed : i64]) : unit
  (with-scratch (set! values (array seed (+ seed 1)))))

;; The global keeps one static home (SPEC 5.10). Each replacement runs in a
;; temporary arena while an element place into that home is captured; the
;; store then lands in the home, and no replacement allocates.
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
        (not (and (= (array-ref values 0) -1) (= (array-ref values 1) (+ i 1))))
        (return 1))
      (+= i 1))
    (when (not (= (profile.alloc-total) before)) (return 2)))
  42)