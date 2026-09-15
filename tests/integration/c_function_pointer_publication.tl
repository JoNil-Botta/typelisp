;; #7725: the ready flag publishes every pointer field. Readers use ordinary
;; immutable pointer loads only after observing the sequentially consistent flag.
(import stdlib.thread)
(import c_function_pointer_dep as dep)

(extern (resolve) : (CFunc nullable (-> i64 i64)) (:symbol "tl_cfn_resolve"))
(extern (resolve-count) : i64 (:symbol "tl_cfn_resolve_count"))

(defstruct Published
  (first (CFunc nullable (-> i64 i64)))
  (second (CFunc nullable (-> i64 i64))))

(define published : Published
  (init : Published))
(define ready : i64
  0)

(define (publish [_context : i64]) : i64
  (begin
    (set! published (Published (resolve) (resolve)))
    (unsafe
      (atomic-store! (ptr-addr-of ready) 1))
    0))

(define (read-published) : i64
  (begin
    (while (=
      (unsafe
        (atomic-load (ptr-addr-of ready)))
      0)
      unit)
    (let
      [selected : (CFunc nullable (-> i64 i64))
        (if (= (resolve-count) 2)
          published.first
          published.second)]
      [checked : (CFunc non-null (-> i64 i64))
        (dep.relay (c-fn-check selected))]
      [assigned : (CFunc non-null (-> i64 i64)) checked]
      (begin
        (set! assigned (c-fn-check published.second))
        (if (and (= (resolve-count) 2) (= (+ (checked 41) (assigned 41)) 84))
          0
          1)))))

(define (main) : i64
  (match (unsafe
    (thread.spawn publish 0))
    [(ThreadSpawnErr _) 2]
    [(ThreadSpawnOk worker)
      (let
        [score : i64 (read-published)]
        [joined : ThreadJoinResult
          (unsafe
            (thread.join worker))]
        (match joined
          [(ThreadJoinOk code)
            (if (= code 0)
              score
              3)]
          [(ThreadJoinErr _) 4]))]))