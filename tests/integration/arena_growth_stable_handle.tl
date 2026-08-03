; Stable first-class arena identity must survive physical segment growth.
(import stdlib.arena)

(extern (tl_alloc [arg0 : u64]) : u64)

(define (raw-head [root : arena.Arena]) : i64
  (unsafe
    (ptr-read
      (int->ptr (+ (arena.raw-handle root) (cast 56 : i64)) : (Ptr i64)))))

(define (main) : i64
  (let
    [home : arena.Arena (arena.current)]
    [owner : arena.Arena (arena.make)]
    (begin
      (unsafe
        (arena.set! owner))
      (let
        [mark : arena.ArenaMark (arena.mark)]
        (begin
          ; Leave exactly one small allocation for the overflow segment.
          (tl_alloc (cast 67108800 : u64))
          (tl_alloc (cast 8 : u64))
          (let
            [grown-head : i64 (raw-head owner)]
            [public-grown : arena.Arena (arena.current)]
            (begin
              (unless
                (and
                  (not (= grown-head (arena.raw-handle owner)))
                  (= (arena.raw-handle public-grown) (arena.raw-handle owner)))
                (return 1))
              ; Passing the physical child to set! must canonicalize to root.
              (unsafe
                (arena.set! (arena.Arena grown-head)))
              (unless
                (= (arena.raw-handle (arena.current)) (arena.raw-handle owner))
                (return 1))
              (unsafe
                (arena.rewind mark))
              (unless (= (raw-head owner) (arena.raw-handle owner)) (return 1))
              (tl_alloc (cast 8 : u64))
              (unsafe
                (begin
                  (arena.set! home)
                  (arena.destroy owner)))
              42)))))))