(defstruct Wide
  (:repr c)
  (a u64)
  (b u64))

(extern (wide-make [a : u32] [b : u32] [c : u32] [d : u32] [tag : u64]) : Wide (:symbol "tl_cabi_wide_make"))

(extern wide-maker (:symbol "tl_cabi_wide_make_ptr") : (->
  u32
  u32
  u32
  u32
  u64
  Wide))

(define (wide-score [value : Wide]) : i64
  (+ (cast (struct-get value a) : i64) (cast (struct-get value b) : i64)))

(define (main) : i64
  (let
    [direct : Wide
      (wide-make
        (cast 1 : u32)
        (cast 2 : u32)
        (cast 3 : u32)
        (cast 4 : u32)
        (cast 10 : u64))]
    [maker : (-> u32 u32 u32 u32 u64 Wide) wide-maker]
    [via-ptr : Wide
      (maker
        (cast 5 : u32)
        (cast 6 : u32)
        (cast 7 : u32)
        (cast 8 : u32)
        (cast 2 : u64))]
    (cond
      [(not (= (wide-score direct) 120)) 1]
      [(not (= (wide-score via-ptr) 52)) 2]
      [else 42])))