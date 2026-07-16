;; compiler_intern_state.tl - explicit worker-owned intern table API.
;;
;; The authoritative table layout and lookup implementation live in
;; compiler_intern. This wrapper gives worker code an explicit owner without
;; duplicating that interner or installing it into the process-global state.
(import compiler_intern as ci)

(defstruct InternState
  (compat ci.InternCompatState))

(define (intern-state-new) : InternState
  (InternState (ci.intern-compat-state-new)))

(define (intern-state-pool-len [state : InternState]) : i64
  (ci.intern-compat-state-pool-len (struct-get state compat)))

(define (intern-state-generation [state : InternState]) : i64
  (ci.intern-compat-state-generation (struct-get state compat)))

(define (intern-state-reset! [state : InternState]) : unit
  (ci.intern-compat-state-reset! (struct-get state compat)))

(define (intern-state-reset-to! [state : InternState] [mark : i64]) : unit
  (ci.intern-compat-state-reset-to! (struct-get state compat) mark))

(define (intern-state-intern [state : InternState] [name : String]) : i64
  (ci.intern-compat-state-intern (struct-get state compat) name))

(define (intern-state-lookup [state : InternState] [name : String]) : ci.InternLookup
  (ci.intern-compat-state-lookup (struct-get state compat) name))

(define (intern-state-str [state : InternState] [id : i64]) : String
  (ci.intern-compat-state-str (struct-get state compat) id))

(define (intern-state-qualified? [state : InternState] [id : i64]) : bool
  (ci.intern-compat-state-qualified? (struct-get state compat) id))

(define (intern-state-qualified-last-slash [state : InternState] [id : i64]) : i64
  (ci.intern-compat-state-qualified-last-slash (struct-get state compat) id))

(define (intern-state-qualified-module-id [state : InternState] [id : i64]) : i64
  (ci.intern-compat-state-qualified-module-id (struct-get state compat) id))

(define (intern-state-qualified-base-id [state : InternState] [id : i64]) : i64
  (ci.intern-compat-state-qualified-base-id (struct-get state compat) id))

(define (intern-state-qualified-module [state : InternState] [id : i64]) : String
  (let
    [module-id : i64 (intern-state-qualified-module-id state id)]
    (if (< module-id 0)
      ""
      (intern-state-str state module-id))))

(define (intern-state-qualified-base [state : InternState] [id : i64]) : String
  (intern-state-str state (intern-state-qualified-base-id state id)))

(define (intern-state-qualified-metadata-case-ok?
  [state : InternState]
  [id : i64]
  [qualified : bool]
  [last-slash : i64]
  [module-name : String]
  [base-name : String]) : bool
  (and
    (= (intern-state-qualified-last-slash state id) last-slash)
    (= (intern-state-qualified? state id) qualified)
    (ci.intern-private-string-eq
      (intern-state-qualified-module state id)
      module-name)
    (ci.intern-private-string-eq
      (intern-state-qualified-base state id)
      base-name)))

(define (intern-state-isolation-tests-ok?) : bool
  (let
    [state-a : InternState (intern-state-new)]
    [state-b : InternState (intern-state-new)]
    [a-alpha : i64 (intern-state-intern state-a "alpha")]
    [b-bravo : i64 (intern-state-intern state-b "bravo")]
    [a-qualified : i64 (intern-state-intern state-a "pkg/name")]
    [b-alpha : i64 (intern-state-intern state-b "alpha")]
    [b-mark : i64 (intern-state-pool-len state-b)]
    [_b-drop : i64 (intern-state-intern state-b "drop")]
    [a-generation : i64 (intern-state-generation state-a)]
    [b-generation : i64 (intern-state-generation state-b)]
    [ok : bool true]
    (begin
      (unless (= a-alpha 0) (set! ok false))
      (unless (= b-bravo 0) (set! ok false))
      (unless (= b-alpha 1) (set! ok false))
      (unless
        (intern-state-qualified-metadata-case-ok?
          state-a
          a-qualified
          true
          3
          "pkg"
          "name")
        (set! ok false))
      (intern-state-reset! state-a)
      (unless
        (not (= (intern-state-generation state-a) a-generation))
        (set! ok false))
      (unless
        (= (intern-state-generation state-b) b-generation)
        (set! ok false))
      (unless (= (intern-state-pool-len state-a) 0) (set! ok false))
      (unless (= (intern-state-intern state-a "alpha") 0) (set! ok false))
      (unless (= (intern-state-pool-len state-b) 3) (set! ok false))
      (unless
        (ci.intern-private-string-eq (intern-state-str state-b b-bravo) "bravo")
        (set! ok false))
      (match (intern-state-lookup state-b "alpha")
        [(ci.InternLookupFound found)
          (unless (= found b-alpha) (set! ok false))]
        [(ci.InternLookupMissing) (set! ok false)])
      (match (intern-state-lookup state-b "drop")
        [(ci.InternLookupFound found) (unless (= found b-mark) (set! ok false))]
        [(ci.InternLookupMissing) (set! ok false)])
      (intern-state-reset-to! state-b b-mark)
      (unless (= (intern-state-pool-len state-b) b-mark) (set! ok false))
      (match (intern-state-lookup state-b "drop")
        [(ci.InternLookupMissing) unit]
        [(ci.InternLookupFound _) (set! ok false)])
      (unless (= (intern-state-intern state-b "drop") b-mark) (set! ok false))
      (unless (= (intern-state-pool-len state-a) 1) (set! ok false))
      (unless
        (ci.intern-private-string-eq (intern-state-str state-a 0) "alpha")
        (set! ok false))
      ok)))