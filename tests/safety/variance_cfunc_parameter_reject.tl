;: A lifetime inside a C function pointer's parameter is contravariant, as in a
;: function type, so `S` cannot be shortened: the callback may keep the
;: holder. Main counted the lifetime bivariant and accepted this (#8449).
(defstruct Holder
  (:lifetimes a)
  (r (& a i64)))

(defstruct S
  (:lifetimes a)
  (cb (CFunc non-null (-> (Holder a) unit))))

(define (shrink [s : (S program)] [q : (& q i64)]) : (S q)
  s)

(define (main) : i64
  0)