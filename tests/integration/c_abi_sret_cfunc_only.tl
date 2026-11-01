;; Only the imported function-pointer value declares this foreign signature.
;; Its canonical sret contract must survive a local alias and parameter relay.
(defstruct SretOnly
  (:repr c)
  (a u64)
  (b u64)
  (c u64))

(extern maker (:symbol "tl_cabi_sret_only_maker") : (CFunc
  non-null
  (-> u64 SretOnly)))

(define (invoke [f : (CFunc non-null (-> u64 SretOnly))] [seed : u64]) : SretOnly
  (f seed))

(define (main) : i64
  (let
    [first : SretOnly (maker (cast 7 : u64))]
    [alias : (CFunc non-null (-> u64 SretOnly)) maker]
    [second : SretOnly (invoke alias (cast 11 : u64))]
    (cond
      [(not (= first.a (cast 7 : u64))) 1]
      [(not (= first.b (cast 17 : u64))) 2]
      [(not (= first.c (cast 27 : u64))) 3]
      [(not (= second.a (cast 11 : u64))) 4]
      [(not (= second.b (cast 21 : u64))) 5]
      [(not (= second.c (cast 31 : u64))) 6]
      [else 42])))