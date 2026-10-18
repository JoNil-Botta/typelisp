(extern (values) : (MutPtr i64) (:symbol "tl_certified_values"))
(extern (resolve) : (CFunc nullable (-> i64 i64)) (:symbol "tl_certified_resolve"))
(extern (resolve-count) : i64 (:symbol "tl_certified_resolve_count"))

(defstruct Pair
  (left i64)
  (right i64))

(define (pair-stride [ptr : (Ptr Pair)]) : u64
  (unsafe
    (- (ptr->int (ptr-offset ptr 1)) (ptr->int ptr))))

(define (numeric [value : i64]) : i64
  (+ (cast (cast value : i8) : i64) (cast (cast -1 : u8) : i64)))

(define (floating [value : f64]) : i64
  (cast (cast value : f32) : i64))

(define (write-and-read [ptr : (MutPtr i64)]) : i64
  (unsafe
    (ptr-write!
      ptr
      (begin
        (set! ptr (ptr-offset ptr 1))
        42))
    (ptr-read (ptr-offset ptr -1))))

(define (round-trip [ptr : (MutPtr i64)]) : i64
  (unsafe
    (ptr-read (int->ptr (ptr->int (ptr-cast ptr : (Ptr u8))) : (Ptr i64)))))

(define (checked [choose : bool]) : i64
  (let
    [func : (CFunc non-null (-> i64 i64))
      (if choose
        (c-fn-check (resolve))
        (c-fn-check (resolve)))]
    (func 41)))

(define (repeated) : i64
  (c-fn-check (resolve))
  ((c-fn-check (resolve)) 41))

(define (wide-literal) : u64
  (cast 0x7ff0000000000000 : u64))

(define (large-literal) : i64
  (cast 4294967338 : i64))

(define (negative-literal) : i64
  (cast -4294967338 : i64))

(define (max-literal) : u64
  (cast 0xffffffffffffffff : u64))

(define (max-round-trip) : i64
  (cast (cast 0xffffffffffffffff : u64) : i64))

(define (main) : i64
  (let
    [ptr : (MutPtr i64) (values)]
    (if (and
      (= (numeric 42) 297)
      (= (large-literal) 4294967338)
      (= (negative-literal) -4294967338)
      (= (wide-literal) 0x7ff0000000000000)
      (= (max-literal) 0xffffffffffffffff)
      (= (max-round-trip) -1)
      (= (floating 42.75) 42)
      (= (write-and-read ptr) 42)
      (= (round-trip ptr) 42)
      (=
        (unsafe
          (ptr-read (ptr-offset ptr 1)))
        41)
      (=
        (unsafe
          (ptr-read (ptr-offset ptr 2)))
        99)
      (=
        (pair-stride
          (unsafe
            (ptr-cast ptr : (Ptr Pair))))
        16)
      (= (checked true) 42)
      (= (checked false) 42)
      (= (repeated) 42)
      (= (resolve-count) 4))
      42
      1)))