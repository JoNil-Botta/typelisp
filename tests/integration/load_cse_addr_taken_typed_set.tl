;; The same through a pointer of another type: the `set!` of the u64 local is a
;; store the second f64 read through its address must see, which gvn's load-CSE
;; forwarded across it (#8514). Exits 42; opt1 and opt2 exited 1.
(define (main) : i64
  (let
    [value : u64 (cast 4607182418800017408 : u64)]
    [p : (MutPtr f64)
      (unsafe
        (ptr-cast (ptr-addr-of value) : (MutPtr f64)))]
    [before : f64
      (unsafe
        (ptr-read p))]
    (set! value (cast 4611686018427387904 : u64))
    (if (=
      (+
        before
        (unsafe
          (ptr-read p)))
      3.0)
      42
      1)))