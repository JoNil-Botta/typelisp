;; Checking either body requires an ownership-graph representation of its call.
(defstruct View
  (:repr c)
  (:lifetimes a)
  (value (& a i64)))

(extern callback : (CFunc non-null (-> (View a) i64)))
(extern (open-tail [view : (View a)] ...) : i64)

(define (indirect [view : (View a)]) : i64
  (callback view))

(define (open-call [view : (View a)]) : i64
  (open-tail view 1))

(define (main) : i64
  0)