(module opaque_dep)

;; Opaque aggregates whose representation stays inside opaque_dep and its
;; dotted descendants (#6999). The rest of the corpus uses them from outside.
(defstruct Connection
  (:opaque)
  (fd i64))

(defenum State
  (:opaque)
  (Idle)
  (Busy i64))

(define (connection-fd [c : (& a Connection)]) : i64
  c.fd)

(define (state-load [s : (& a State)]) : i64
  (match (deref s)
    [(Idle) 0]
    [(Busy n) n]))

(define (with-connection [fd : i64] [f : (-> (& a Connection) i64)]) : i64
  (let
    [c : Connection (Connection fd)]
    (f (& c))))

;; A function whose result holds the type by value: callable only inside the
;; family.
(define (make [fd : i64]) : Connection
  (Connection fd))

(defmacro (make-connection [fd : Expr]) : Expr
  `(Connection ,fd))