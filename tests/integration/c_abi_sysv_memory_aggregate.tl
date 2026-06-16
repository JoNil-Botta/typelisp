;; #1984: Linux System V MEMORY-class aggregate C ABI. Aggregates larger than
;; two eightbytes are copied by value to the outgoing stack area for direct and
;; indirect extern calls, while MEMORY-class returns use the hidden sret pointer.
(defstruct WideMem
  (:repr c)
  (a u64)
  (b u64)
  (c u64))

(defstruct InnerMem
  (:repr c)
  (lo u64)
  (hi u64))

(defstruct NestedMem
  (:repr c)
  (inner InnerMem)
  (tail u64))

(extern (wide-mem-score [arg0 : WideMem] [salt : u64]) : i64 (:symbol "tl_cabi_wide_mem_score"))
(extern wide-mem-scorer (:symbol "tl_cabi_wide_mem_score_ptr") : (->
  WideMem
  u64
  i64))
(extern (wide-mem-make [seed : u64]) : WideMem (:symbol "tl_cabi_wide_mem_make"))
(extern (nested-mem-score [arg0 : NestedMem]) : i64 (:symbol "tl_cabi_nested_mem_score"))

(define (main) : i64
  (let
    [direct-arg : WideMem
      (WideMem (cast 1 : u64) (cast 2 : u64) (cast 3 : u64))]
    [ptr-arg : WideMem (WideMem (cast 5 : u64) (cast 6 : u64) (cast 7 : u64))]
    [nested : NestedMem
      (NestedMem (InnerMem (cast 3 : u64) (cast 4 : u64)) (cast 5 : u64))]
    [score-copy : (-> WideMem u64 i64) wide-mem-scorer]
    [direct : i64 (wide-mem-score direct-arg (cast 4 : u64))]
    [via-ptr : i64 (score-copy ptr-arg (cast 8 : u64))]
    [made : WideMem (wide-mem-make (cast 9 : u64))]
    [nested-score : i64 (nested-mem-score nested)]
    (begin
      (unless (= direct 38) (return 1))
      (unless (= via-ptr 84) (return 2))
      (unless (= (struct-get made a) (cast 19 : u64)) (return 3))
      (unless (= (struct-get made b) (cast 29 : u64)) (return 4))
      (unless (= (struct-get made c) (cast 39 : u64)) (return 5))
      (unless (= nested-score 26) (return 6))
      42)))