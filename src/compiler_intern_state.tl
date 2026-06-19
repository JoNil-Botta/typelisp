;; compiler_intern_state.tl - explicit worker-owned intern table API.
;;
;; This module is intentionally separate from compiler_intern.tl while the
;; existing compiler call graph still uses the long-standing single-compile
;; wrappers. Worker code can allocate an InternState and use the intern-state-*
;; functions below without touching the process-global compatibility table,
;; builtin-id cache, backend symbol cache, or typecheck caches keyed by
;; intern-generation.
(import "compiler_intern.tl")

(defstruct InternState
  (pool-slots (Array String))
  (pool-qualified-slots (Array bool))
  (pool-last-slash-slots (Array i64))
  (pool-first-dot-slots (Array i64))
  (pool-module-id-slots (Array i64))
  (pool-base-id-slots (Array i64))
  (pool-count (Array i64))
  (map-slots (Array InternSlot))
  (map-ready (Array bool))
  (reset-generation (Array i64)))

(define (intern-state-new) : InternState
  (let
    [pool-count : (Array i64) (make-array i64 1)]
    [map-ready : (Array bool) (make-array bool 1)]
    [reset-generation : (Array i64) (make-array i64 1)]
    (begin
      (array-set! pool-count 0 0)
      (array-set! map-ready 0 false)
      (array-set! reset-generation 0 0)
      (InternState
        (make-array String 262144)
        (make-array bool 262144)
        (make-array i64 262144)
        (make-array i64 262144)
        (make-array i64 262144)
        (make-array i64 262144)
        pool-count
        (make-array InternSlot 262144)
        map-ready
        reset-generation))))

(define (intern-state-pool-len [state : InternState]) : i64
  (array-ref (struct-get state pool-count) 0))

(define (intern-state-generation [state : InternState]) : i64
  (array-ref (struct-get state reset-generation) 0))

(define (intern-state-set-pool-len! [state : InternState] [len : i64]) : unit
  (array-set! (struct-get state pool-count) 0 len))

(define (intern-state-map-ready? [state : InternState]) : bool
  (array-ref (struct-get state map-ready) 0))

(define (intern-state-set-map-ready! [state : InternState] [ready : bool]) : unit
  (array-set! (struct-get state map-ready) 0 ready))

(define (intern-state-bump-generation! [state : InternState]) : unit
  (array-set!
    (struct-get state reset-generation)
    0
    (+ (intern-state-generation state) 1)))

(define (intern-state-fill-empty
  [state : InternState]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! (struct-get state map-slots) index (InternEmpty))
      (intern-state-fill-empty state (+ index 1) count))))

(define (intern-state-map-insert-existing-from
  [state : InternState]
  [name : String]
  [id : i64]
  [hash : i64]
  [cursor : i64]
  [steps : i64]
  [capacity : i64]) : unit
  (if (>= steps capacity)
    unit
    (match (array-ref (struct-get state map-slots) cursor)
      [(InternEmpty)
        (array-set!
          (struct-get state map-slots)
          cursor
          (InternUsed name id hash))]
      [_
        (intern-state-map-insert-existing-from
          state
          name
          id
          hash
          (intern-bucket (+ cursor 1) capacity)
          (+ steps 1)
          capacity)])))

(define (intern-state-map-insert-existing! [state : InternState] [id : i64]) : unit
  (let
    [name : String (array-ref (struct-get state pool-slots) id)]
    [hash : i64 (intern-hash name)]
    [capacity : i64 (array-length (struct-get state map-slots))]
    (intern-state-map-insert-existing-from
      state
      name
      id
      hash
      (intern-bucket hash capacity)
      0
      capacity)))

(define (intern-state-map-rebuild-prefix
  [state : InternState]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (intern-state-map-insert-existing! state index)
      (intern-state-map-rebuild-prefix state (+ index 1) count))))

(define (intern-state-reset! [state : InternState]) : unit
  (begin
    (intern-state-set-pool-len! state 0)
    (intern-state-fill-empty
      state
      0
      (array-length (struct-get state map-slots)))
    (intern-state-bump-generation! state)
    (intern-state-set-map-ready! state true)))

(define (intern-state-reset-to! [state : InternState] [mark : i64]) : unit
  (begin
    (intern-state-set-pool-len! state mark)
    (intern-state-fill-empty
      state
      0
      (array-length (struct-get state map-slots)))
    (intern-state-map-rebuild-prefix state 0 mark)
    (intern-state-bump-generation! state)
    (intern-state-set-map-ready! state true)))

(define (intern-state-record-qualified-metadata
  [state : InternState]
  [id : i64]
  [name : String]) : unit
  (let
    [i : i64 0]
    [n : i64 (string-length name)]
    [slash : i64 -1]
    [dot : i64 -1]
    (begin
      (while (< i n)
        (let
          [c : char (string-ref name i)]
          (begin
            (if (= c '/')
              (set! slash i)
              unit)
            (if (and (< dot 0) (= c '.'))
              (set! dot i)
              unit)
            (set! i (+ i 1)))))
      (array-set! (struct-get state pool-last-slash-slots) id slash)
      (array-set! (struct-get state pool-first-dot-slots) id dot)
      (if (< slash 0)
        (begin
          (array-set! (struct-get state pool-qualified-slots) id false)
          (array-set! (struct-get state pool-module-id-slots) id -1)
          (array-set! (struct-get state pool-base-id-slots) id id))
        (let
          [base-start : i64 (+ slash 1)]
          [module-name : String (intern-substring name 0 slash)]
          [base-name : String
            (intern-substring
              name
              base-start
              (- (string-length name) base-start))]
          (begin
            (array-set! (struct-get state pool-qualified-slots) id true)
            (array-set!
              (struct-get state pool-module-id-slots)
              id
              (intern-state-intern state module-name))
            (array-set!
              (struct-get state pool-base-id-slots)
              id
              (intern-state-intern state base-name))))))))

(define (intern-state-intern [state : InternState] [name : String]) : i64
  (begin
    (if (intern-state-map-ready? state)
      unit
      (intern-state-reset! state))
    (let
      [capacity : i64 (array-length (struct-get state map-slots))]
      [hash : i64 (intern-hash name)]
      [cursor : i64 (intern-bucket hash capacity)]
      [steps : i64 0]
      [out : i64 -1]
      [done : bool false]
      (begin
        (while (if done
          false
          (< steps capacity))
          (match (array-ref (struct-get state map-slots) cursor)
            [(InternEmpty)
              (let
                [id : i64 (intern-state-pool-len state)]
                (begin
                  (array-set! (struct-get state pool-slots) id name)
                  (array-set!
                    (struct-get state map-slots)
                    cursor
                    (InternUsed name id hash))
                  (intern-state-set-pool-len! state (+ id 1))
                  (intern-state-record-qualified-metadata state id name)
                  (set! out id)
                  (set! done true)))]
            [(InternUsed slot-key slot-id slot-hash)
              (if (if (= slot-hash hash)
                (string-eq slot-key name)
                false)
                (begin
                  (set! out slot-id)
                  (set! done true))
                (begin
                  (set! cursor (intern-bucket (+ cursor 1) capacity))
                  (set! steps (+ steps 1))))]))
        out))))

(define (intern-state-lookup [state : InternState] [name : String]) : InternLookup
  (if (intern-state-map-ready? state)
    (let
      [capacity : i64 (array-length (struct-get state map-slots))]
      [hash : i64 (intern-hash name)]
      [cursor : i64 (intern-bucket hash capacity)]
      [steps : i64 0]
      [out : InternLookup InternLookupMissing]
      [done : bool false]
      (begin
        (while (if done
          false
          (< steps capacity))
          (match (array-ref (struct-get state map-slots) cursor)
            [(InternEmpty)
              (begin
                (set! out (InternLookupMissing))
                (set! done true))]
            [(InternUsed slot-key slot-id slot-hash)
              (if (if (= slot-hash hash)
                (string-eq slot-key name)
                false)
                (begin
                  (set! out (InternLookupFound slot-id))
                  (set! done true))
                (begin
                  (set! cursor (intern-bucket (+ cursor 1) capacity))
                  (set! steps (+ steps 1))))]))
        out))
    (InternLookupMissing)))

(define (intern-state-str [state : InternState] [id : i64]) : String
  (array-ref (struct-get state pool-slots) id))

(define (intern-state-qualified? [state : InternState] [id : i64]) : bool
  (array-ref (struct-get state pool-qualified-slots) id))

(define (intern-state-qualified-last-slash [state : InternState] [id : i64]) : i64
  (array-ref (struct-get state pool-last-slash-slots) id))

(define (intern-state-qualified-module-id [state : InternState] [id : i64]) : i64
  (array-ref (struct-get state pool-module-id-slots) id))

(define (intern-state-qualified-base-id [state : InternState] [id : i64]) : i64
  (array-ref (struct-get state pool-base-id-slots) id))

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
    (string-eq (intern-state-qualified-module state id) module-name)
    (string-eq (intern-state-qualified-base state id) base-name)))

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
        (= (intern-state-generation state-a) (+ a-generation 1))
        (set! ok false))
      (unless
        (= (intern-state-generation state-b) b-generation)
        (set! ok false))
      (unless (= (intern-state-pool-len state-a) 0) (set! ok false))
      (unless (= (intern-state-intern state-a "alpha") 0) (set! ok false))
      (unless (= (intern-state-pool-len state-b) 3) (set! ok false))
      (unless
        (string-eq (intern-state-str state-b b-bravo) "bravo")
        (set! ok false))
      (match (intern-state-lookup state-b "alpha")
        [(InternLookupFound found) (unless (= found b-alpha) (set! ok false))]
        [(InternLookupMissing) (set! ok false)])
      (match (intern-state-lookup state-b "drop")
        [(InternLookupFound found) (unless (= found b-mark) (set! ok false))]
        [(InternLookupMissing) (set! ok false)])
      (intern-state-reset-to! state-b b-mark)
      (unless (= (intern-state-pool-len state-b) b-mark) (set! ok false))
      (match (intern-state-lookup state-b "drop")
        [(InternLookupMissing) unit]
        [(InternLookupFound _) (set! ok false)])
      (unless (= (intern-state-intern state-b "drop") b-mark) (set! ok false))
      (unless (= (intern-state-pool-len state-a) 1) (set! ok false))
      (unless (string-eq (intern-state-str state-a 0) "alpha") (set! ok false))
      ok)))