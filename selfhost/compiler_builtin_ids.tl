;; compiler_builtin_ids.tl - reset-aware intern ids for fixed compiler builtins.
(import "compiler_intern.tl")

(define compiler-builtin-generation : i64
  -1)

(define compiler-builtin-id-tl-alloc : i64
  -1)

(define compiler-builtin-id-tl-region-mark : i64
  -1)

(define compiler-builtin-id-tl-region-reset : i64
  -1)

(define compiler-builtin-id-tl-arena-make : i64
  -1)

(define compiler-builtin-id-tl-arena-current : i64
  -1)

(define compiler-builtin-id-tl-arena-set : i64
  -1)

(define compiler-builtin-id-tl-arena-destroy : i64
  -1)

(define compiler-builtin-id-tl-arena-poison-enable : i64
  -1)

(define compiler-builtin-id-tl-profile-alloc-total : i64
  -1)

(define compiler-builtin-id-tl-profile-alloc-live : i64
  -1)

(define compiler-builtin-id-tl-profile-alloc-peak : i64
  -1)

(define compiler-builtin-id-tl-profile-alloc-reset-peak : i64
  -1)

(define compiler-builtin-id-tl-substring : i64
  -1)

(define compiler-builtin-id-tl-string-concat : i64
  -1)

(define compiler-builtin-id-tl-string-concat3 : i64
  -1)

(define compiler-builtin-id-tl-string-concat4 : i64
  -1)

(define compiler-builtin-id-tl-string-concat5 : i64
  -1)

(define compiler-builtin-id-tl-string-eq : i64
  -1)

(define compiler-builtin-id-tl-string-to-int : i64
  -1)

(define compiler-builtin-id-tl-int-to-string : i64
  -1)

(define compiler-builtin-id-tl-hash-string : i64
  -1)

(define compiler-builtin-id-tl-env-var-exists : i64
  -1)

(define compiler-builtin-id-tl-env-var-value : i64
  -1)

(define compiler-builtin-id-env-path-separator : i64
  -1)

(define compiler-builtin-id-tl-oob-abort : i64
  -1)

(define compiler-builtin-id-tl-abort-label : i64
  -1)

(define compiler-builtin-id-tl-div-abort : i64
  -1)

(define compiler-builtin-id-tl-shift-abort : i64
  -1)

(define compiler-builtin-id-string-length : i64
  -1)

(define compiler-builtin-id-length : i64
  -1)

(define compiler-builtin-id-string-eq : i64
  -1)

(define compiler-builtin-id-string-eq-question : i64
  -1)

(define compiler-builtin-id-string-to-int : i64
  -1)

(define compiler-builtin-id-string-ref : i64
  -1)

(define compiler-builtin-id-char-at : i64
  -1)

(define compiler-builtin-id-array-length : i64
  -1)

(define compiler-builtin-id-cpuid : i64
  -1)

(define compiler-builtin-id-xgetbv : i64
  -1)

(define compiler-builtin-id-clone : i64
  -1)

(define compiler-builtin-id-arena-make : i64
  -1)

(define compiler-builtin-id-arena-current : i64
  -1)

(define compiler-builtin-id-arena-mark : i64
  -1)

(define compiler-builtin-id-arena-set-bang : i64
  -1)

(define compiler-builtin-id-arena-destroy : i64
  -1)

(define compiler-builtin-id-arena-rewind : i64
  -1)

(define (compiler-builtin-reset!) : unit
  (set! compiler-builtin-generation -1))

(define (compiler-builtin-refresh!) : unit
  (if (= compiler-builtin-generation (intern-generation))
    unit
    (begin
      (set! compiler-builtin-id-tl-alloc (intern "tl_alloc"))
      (set! compiler-builtin-id-tl-region-mark (intern "tl_region_mark"))
      (set! compiler-builtin-id-tl-region-reset (intern "tl_region_reset"))
      (set! compiler-builtin-id-tl-arena-make (intern "tl_arena_make"))
      (set! compiler-builtin-id-tl-arena-current (intern "tl_arena_current"))
      (set! compiler-builtin-id-tl-arena-set (intern "tl_arena_set"))
      (set! compiler-builtin-id-tl-arena-destroy (intern "tl_arena_destroy"))
      (set!
        compiler-builtin-id-tl-arena-poison-enable
        (intern "tl_arena_poison_enable"))
      (set!
        compiler-builtin-id-tl-profile-alloc-total
        (intern "tl_profile_alloc_total"))
      (set!
        compiler-builtin-id-tl-profile-alloc-live
        (intern "tl_profile_alloc_live"))
      (set!
        compiler-builtin-id-tl-profile-alloc-peak
        (intern "tl_profile_alloc_peak"))
      (set!
        compiler-builtin-id-tl-profile-alloc-reset-peak
        (intern "tl_profile_alloc_reset_peak"))
      (set! compiler-builtin-id-tl-substring (intern "tl_substring"))
      (set! compiler-builtin-id-tl-string-concat (intern "tl_string_concat"))
      (set! compiler-builtin-id-tl-string-concat3 (intern "tl_string_concat3"))
      (set! compiler-builtin-id-tl-string-concat4 (intern "tl_string_concat4"))
      (set! compiler-builtin-id-tl-string-concat5 (intern "tl_string_concat5"))
      (set! compiler-builtin-id-tl-string-eq (intern "tl_string_eq"))
      (set! compiler-builtin-id-tl-string-to-int (intern "tl_string_to_int"))
      (set! compiler-builtin-id-tl-int-to-string (intern "tl_int_to_string"))
      (set! compiler-builtin-id-tl-hash-string (intern "tl_hash_string"))
      (set! compiler-builtin-id-tl-env-var-exists (intern "tl_env_var_exists"))
      (set! compiler-builtin-id-tl-env-var-value (intern "tl_env_var_value"))
      (set!
        compiler-builtin-id-env-path-separator
        (intern "env-path-separator"))
      (set! compiler-builtin-id-tl-oob-abort (intern "tl_oob_abort"))
      (set! compiler-builtin-id-tl-abort-label (intern ".L_tl_abort"))
      (set! compiler-builtin-id-tl-div-abort (intern "tl_div_abort"))
      (set! compiler-builtin-id-tl-shift-abort (intern "tl_shift_abort"))
      (set! compiler-builtin-id-string-length (intern "string-length"))
      (set! compiler-builtin-id-length (intern "length"))
      (set! compiler-builtin-id-string-eq (intern "string-eq"))
      (set! compiler-builtin-id-string-eq-question (intern "string=?"))
      (set! compiler-builtin-id-string-to-int (intern "string->int"))
      (set! compiler-builtin-id-string-ref (intern "string-ref"))
      (set! compiler-builtin-id-char-at (intern "char-at"))
      (set! compiler-builtin-id-array-length (intern "array-length"))
      (set! compiler-builtin-id-cpuid (intern "cpuid"))
      (set! compiler-builtin-id-xgetbv (intern "xgetbv"))
      (set! compiler-builtin-id-clone (intern "clone"))
      (set! compiler-builtin-id-arena-make (intern "arena-make"))
      (set! compiler-builtin-id-arena-current (intern "arena-current"))
      (set! compiler-builtin-id-arena-mark (intern "arena-mark"))
      (set! compiler-builtin-id-arena-set-bang (intern "arena-set!"))
      (set! compiler-builtin-id-arena-destroy (intern "arena-destroy"))
      (set! compiler-builtin-id-arena-rewind (intern "arena-rewind"))
      (set! compiler-builtin-generation (intern-generation)))))

(define (compiler-builtin-id-any2? [name-id : i64] [a : i64] [b : i64]) : bool
  (or (= name-id a) (= name-id b)))

(define (compiler-builtin-id-any3?
  [name-id : i64]
  [a : i64]
  [b : i64]
  [c : i64]) : bool
  (or (= name-id a) (compiler-builtin-id-any2? name-id b c)))

(define (compiler-builtin-id-any4?
  [name-id : i64]
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]) : bool
  (or (= name-id a) (compiler-builtin-id-any3? name-id b c d)))

(define (compiler-builtin-backend-runtime-core-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (or
      (compiler-builtin-id-any4?
        name-id
        compiler-builtin-id-tl-alloc
        compiler-builtin-id-tl-region-mark
        compiler-builtin-id-tl-region-reset
        compiler-builtin-id-tl-arena-make)
      (compiler-builtin-id-any4?
        name-id
        compiler-builtin-id-tl-arena-current
        compiler-builtin-id-tl-arena-set
        compiler-builtin-id-tl-arena-destroy
        compiler-builtin-id-tl-arena-poison-enable))))

(define (compiler-builtin-backend-runtime-stdlib-ffi-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (compiler-builtin-id-any4?
      name-id
      compiler-builtin-id-tl-profile-alloc-total
      compiler-builtin-id-tl-profile-alloc-live
      compiler-builtin-id-tl-profile-alloc-peak
      compiler-builtin-id-tl-profile-alloc-reset-peak)))

(define (compiler-builtin-backend-runtime-stdlib-type-lisp-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (or
      (compiler-builtin-id-any4?
        name-id
        compiler-builtin-id-tl-substring
        compiler-builtin-id-tl-string-concat
        compiler-builtin-id-tl-string-concat3
        compiler-builtin-id-tl-string-concat4)
      (or
        (compiler-builtin-id-any4?
          name-id
          compiler-builtin-id-tl-string-concat5
          compiler-builtin-id-tl-string-eq
          compiler-builtin-id-tl-string-to-int
          compiler-builtin-id-tl-int-to-string)
        (= name-id compiler-builtin-id-tl-hash-string)))))

(define (compiler-builtin-backend-runtime-compatibility-alias-id?
  [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (compiler-builtin-id-any3?
      name-id
      compiler-builtin-id-tl-env-var-exists
      compiler-builtin-id-tl-env-var-value
      compiler-builtin-id-env-path-separator)))

(define (compiler-builtin-backend-runtime-helper-known-id? [name-id : i64]) : bool
  (or
    (compiler-builtin-backend-runtime-core-id? name-id)
    (or
      (compiler-builtin-backend-runtime-stdlib-ffi-id? name-id)
      (or
        (compiler-builtin-backend-runtime-stdlib-type-lisp-id? name-id)
        (compiler-builtin-backend-runtime-compatibility-alias-id? name-id)))))

(define (compiler-builtin-backend-runtime-concat-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (compiler-builtin-id-any4?
      name-id
      compiler-builtin-id-tl-string-concat
      compiler-builtin-id-tl-string-concat3
      compiler-builtin-id-tl-string-concat4
      compiler-builtin-id-tl-string-concat5)))

(define (compiler-builtin-backend-runtime-profile-id? [name-id : i64]) : bool
  (compiler-builtin-backend-runtime-stdlib-ffi-id? name-id))

(define (compiler-builtin-backend-runtime-always-provided-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (compiler-builtin-id-any4?
      name-id
      compiler-builtin-id-tl-arena-poison-enable
      compiler-builtin-id-tl-arena-make
      compiler-builtin-id-tl-arena-current
      compiler-builtin-id-tl-arena-set)))

(define (compiler-builtin-backend-runtime-always-provided-tail-id?
  [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tl-arena-destroy)))

(define (compiler-builtin-backend-tl-alloc-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tl-alloc)))

(define (compiler-builtin-backend-tl-region-mark-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tl-region-mark)))

(define (compiler-builtin-backend-tl-region-reset-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tl-region-reset)))

(define (compiler-builtin-backend-tl-oob-abort-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tl-oob-abort)))

(define (compiler-builtin-backend-tl-substring-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tl-substring)))

(define (compiler-builtin-backend-tl-string-eq-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tl-string-eq)))

(define (compiler-builtin-backend-tl-string-to-int-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tl-string-to-int)))

(define (compiler-builtin-backend-tl-int-to-string-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tl-int-to-string)))

(define (compiler-builtin-backend-tl-abort-label-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tl-abort-label)))

(define (compiler-builtin-backend-tl-div-abort-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tl-div-abort)))

(define (compiler-builtin-backend-tl-shift-abort-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tl-shift-abort)))

(define (compiler-builtin-backend-tl-hash-string-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tl-hash-string)))

(define (compiler-builtin-backend-env-var-exists-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tl-env-var-exists)))

(define (compiler-builtin-backend-env-var-value-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tl-env-var-value)))

(define (compiler-builtin-backend-env-path-separator-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-env-path-separator)))

(define (compiler-builtin-lower-bootstrap-runtime-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (compiler-builtin-id-any3?
      name-id
      compiler-builtin-id-string-eq
      compiler-builtin-id-string-eq-question
      compiler-builtin-id-string-to-int)))

(define (compiler-builtin-lower-arena-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (or
      (compiler-builtin-id-any4?
        name-id
        compiler-builtin-id-arena-make
        compiler-builtin-id-arena-current
        compiler-builtin-id-arena-mark
        compiler-builtin-id-arena-set-bang)
      (compiler-builtin-id-any2?
        name-id
        compiler-builtin-id-arena-destroy
        compiler-builtin-id-arena-rewind))))

(define (compiler-builtin-lower-arena-nullary-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (compiler-builtin-id-any3?
      name-id
      compiler-builtin-id-arena-make
      compiler-builtin-id-arena-current
      compiler-builtin-id-arena-mark)))

(define (compiler-builtin-lower-arena-make-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-arena-make)))

(define (compiler-builtin-lower-arena-current-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-arena-current)))

(define (compiler-builtin-lower-arena-mark-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-arena-mark)))

(define (compiler-builtin-lower-arena-set-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-arena-set-bang)))

(define (compiler-builtin-lower-arena-destroy-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-arena-destroy)))

(define (compiler-builtin-lower-string-ref-call-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (compiler-builtin-id-any2?
      name-id
      compiler-builtin-id-string-ref
      compiler-builtin-id-char-at)))

(define (compiler-builtin-lower-length-call-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (compiler-builtin-id-any3?
      name-id
      compiler-builtin-id-array-length
      compiler-builtin-id-length
      compiler-builtin-id-string-length)))

(define (compiler-builtin-lower-array-length-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-array-length)))

(define (compiler-builtin-lower-cpuid-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-cpuid)))

(define (compiler-builtin-lower-xgetbv-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-xgetbv)))

(define (compiler-builtin-lower-clone-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-clone)))

(define (compiler-builtin-typecheck-region-arg-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (or
      (compiler-builtin-id-any4?
        name-id
        compiler-builtin-id-string-length
        compiler-builtin-id-length
        compiler-builtin-id-string-eq
        compiler-builtin-id-string-eq-question)
      (= name-id compiler-builtin-id-string-to-int))))