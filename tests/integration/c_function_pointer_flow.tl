;; #7725: C addresses retain their signature and calling convention through
;; higher-order return, global storage, imports, aggregates and closure capture.
(import c_function_pointer_dep as dep)

(extern (resolve) : (CFunc nullable (-> i64 i64)) (:symbol "tl_cfn_resolve"))
(extern (resolve-count) : i64 (:symbol "tl_cfn_resolve_count"))
(extern entry (:symbol "tl_cfn_entry") : (CFunc non-null (-> i64 i64)))

(defstruct Table
  (entry (CFunc non-null (-> i64 i64))))

(defenum Choice
  (Missing)
  (Ready (CFunc non-null (-> i64 i64))))

(extern (table-score [table : Table]) : i64 (:symbol "tl_cfn_table_score") (:abi c))

(define (factory [resolver : (-> (CFunc nullable (-> i64 i64)))]) : (CFunc
    nullable
    (-> i64 i64))
  (resolver))

(define saved : (CFunc nullable (-> i64 i64))
  (factory resolve))

(define (make-call [f : (CFunc non-null (-> i64 i64))]) : (-> i64 i64)
  (lambda ([x : i64]) : i64
    (f x)))

(define (main) : i64
  (let
    [f : (CFunc non-null (-> i64 i64)) (dep.relay (c-fn-check saved))]
    [table : Table (Table f)]
    [choice : Choice (Choice.Ready f)]
    [call : (-> i64 i64) (make-call (c-fn-check (resolve)))]
    [enum-score : i64
      (match choice
        [(Choice.Missing) 0]
        [(Choice.Ready selected) (selected 41)])]
    (if (and
      (= (resolve-count) 2)
      (=
        (+
          (+ (+ (f 41) (table.entry 41)) (+ (entry 41) (call 41)))
          (+ enum-score (table-score table)))
        252))
      0
      1)))