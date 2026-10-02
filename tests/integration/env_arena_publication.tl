;; Public environment mutation publishes process-lifetime storage whatever arena
;; is active (#7658). Two consecutive jobs set, replace and remove variables from
;; nested temporary arenas; once those arenas are gone and fresh storage has been
;; written, lookups and (on Linux) a spawned child see exactly the published
;; values, and the first job's values survive the second job's tables. A direct
;; call of the Linux mutator validates its inputs like `set!` and `unset!`.
(import stdlib.env)
(import stdlib.process)
(import stdlib.str_cat)
(import stdlib.string)

(define (env-arena-name [job : i64] [slot : String]) : String
  (str_cat.str-cat "TL_ENV_ARENA_J" (string.int->string job) "_" slot))

;; Write fresh storage, so a table left in a finished arena would already have
;; been reused or unmapped by the next lookup.
(define (env-arena-scrub) : unit
  (with-arena
    scrub
    (let
      [junk : (__tl_dyn-array u8) (__tl_make-array u8 65536)]
      [index : i64 0]
      (while (< index 65536)
        (begin
          (set! (array-ref junk index) (cast 90 : u8))
          (set! index (+ index 1)))))))

(define (env-arena-value-is? [name : String] [want : String]) : bool
  (match (env.get (& name))
    [(EnvSomeString actual) (string.eq actual want)]
    [(EnvNoString) false]))

;; A spawned child inherits the published table.
(define (env-arena-child-sees? [name : String] [want : String]) : bool
  (match (process.output
    (process.command
      "/bin/sh"
      (process.args-cons
        "-c"
        (process.args-cons
          (str_cat.str-cat "printf '%s' \"$" name "\"")
          (process.args-empty)))))
    [(OkProcessOutput output)
      (and
        (= (process.output-status output) 0)
        (string.eq (process.output-stdout output) want))]
    [(ErrProcessOutput _) false]))

;; One job: 0 on success, otherwise the code of the first failed check.
(define (env-arena-job [job : i64]) : i64
  (let
    [kept : String (env-arena-name job "KEPT")]
    [replaced : String (env-arena-name job "REPLACED")]
    [removed : String (env-arena-name job "REMOVED")]
    [set-ok : bool
      (with-arena
        outer
        (with-arena
          inner
          (and
            (env.set! (& kept) "kept")
            (env.set! (& replaced) "old")
            (env.set! (& removed) "gone"))))]
    [replace-ok : bool (with-arena outer (env.set! (& replaced) "new"))]
    [remove-ok : bool (with-arena outer (env.unset! (& removed)))]
    [_scrub : unit (env-arena-scrub)]
    (cond
      [(not set-ok) 1]
      [(not replace-ok) 2]
      [(not remove-ok) 3]
      [(not (env-arena-value-is? (string.copy (& kept)) "kept")) 4]
      [(not (env-arena-value-is? (string.copy (& replaced)) "new")) 5]
      [(env.var-exists? (& removed)) 6]
      [(not (cfg windows true (env-arena-child-sees? kept "kept"))) 7]
      [else 0])))

;; An owned three-byte string with an interior NUL.
(define (env-arena-with-nul) : String
  (let
    [bytes : (__tl_dyn-array u8) (__tl_make-array u8 3)]
    (begin
      (set! (array-ref bytes 0) (cast 'a' : u8))
      (set! (array-ref bytes 1) (cast 0 : u8))
      (set! (array-ref bytes 2) (cast 'b' : u8))
      (unsafe
        (string-from-bytes (ptr-cast (__tl_array-data bytes) : (Ptr u8)) 3)))))

;; The Linux mutator is callable from safe code and validates like `set!`.
(define (env-arena-direct-mutator-validates?) : bool
  (cfg
    windows
    true
    (let
      [name : String "TL_ENV_ARENA_DIRECT"]
      [with-nul : String (env-arena-with-nul)]
      (and
        (not (env.linux-mutate! "" "value" true))
        (not (env.linux-mutate! "TL=ENV" "value" true))
        (not (env.linux-mutate! "TL=ENV" "" false))
        (not (env.linux-mutate! (& with-nul) "value" true))
        (not (env.linux-mutate! (& name) (& with-nul) true))
        (not (env.var-exists? (& name)))
        (env.linux-mutate! (& name) "direct" true)
        (env-arena-value-is? (string.copy (& name)) "direct")
        ;; Removal ignores the value.
        (env.linux-mutate! (& name) (& with-nul) false)
        (not (env.var-exists? (& name)))))))

(define (main) : i64
  (let
    [first : i64 (env-arena-job 1)]
    [second : i64 (env-arena-job 2)]
    (cond
      [(not (= first 0)) first]
      [(not (= second 0)) (+ 10 second)]
      [(not (env-arena-value-is? (env-arena-name 1 "KEPT") "kept")) 21]
      [(not (env-arena-value-is? (env-arena-name 1 "REPLACED") "new")) 22]
      [(not (env-arena-direct-mutator-validates?)) 23]
      [else 42])))