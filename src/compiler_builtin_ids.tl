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
(define compiler-builtin-id-tl-arena-make-atomic : i64
  -1)
(define compiler-builtin-id-tl-arena-current : i64
  -1)
(define compiler-builtin-id-tl-arena-set : i64
  -1)
(define compiler-builtin-id-tl-arena-destroy : i64
  -1)
(define compiler-builtin-id-tl-arena-poison-enable : i64
  -1)
(define compiler-builtin-id-tl-thread-entry-ptr : i64
  -1)
(define compiler-builtin-id-tl-thread-init : i64
  -1)
(define compiler-builtin-id-tl-atomic-i64-load-ptr : i64
  -1)
(define compiler-builtin-id-tl-atomic-i64-store-ptr : i64
  -1)
(define compiler-builtin-id-tl-atomic-i64-add-ptr : i64
  -1)
(define compiler-builtin-id-tl-atomic-i64-fetch-add-ptr : i64
  -1)
(define compiler-builtin-id-tl-atomic-i64-cas-ptr : i64
  -1)
(define compiler-builtin-id-tl-atomic-i32-load-ptr : i64
  -1)
(define compiler-builtin-id-tl-atomic-i32-store-ptr : i64
  -1)
(define compiler-builtin-id-tl-atomic-i32-add-ptr : i64
  -1)
(define compiler-builtin-id-tl-atomic-i32-fetch-add-ptr : i64
  -1)
(define compiler-builtin-id-tl-atomic-i32-cas-ptr : i64
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
(define compiler-builtin-id-tl-str-view : i64
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
(define compiler-builtin-id-tl-array-fill8 : i64
  -1)
(define compiler-builtin-id-tl-array-zero : i64
  -1)
(define compiler-builtin-id-tl-print-char : i64
  -1)
(define compiler-builtin-id-tl-print-f64 : i64
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
(define compiler-builtin-id-arena-make-atomic : i64
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

(defstruct CompilerBuiltinIdsState
  (generation (Array i64))
  (ids (Array i64)))

(define (compiler-builtin-ids-state-new) : CompilerBuiltinIdsState
  (let
    [generation : (Array i64) (make-array i64 1)]
    [ids : (Array i64) (make-array i64 64)]
    [i : i64 0]
    (begin
      (array-set! generation 0 -1)
      (while (< i 64)
        (begin
          (array-set! ids i -1)
          (set! i (+ i 1))))
      (CompilerBuiltinIdsState generation ids))))

(define (compiler-builtin-ids-state-generation
  [state : CompilerBuiltinIdsState]) : i64
  (array-ref (struct-get state generation) 0))

(define (compiler-builtin-ids-state-set-generation!
  [state : CompilerBuiltinIdsState]
  [generation : i64]) : unit
  (array-set! (struct-get state generation) 0 generation))

(define (compiler-builtin-ids-state-ref
  [state : CompilerBuiltinIdsState]
  [index : i64]) : i64
  (array-ref (struct-get state ids) index))

(define (compiler-builtin-ids-state-set!
  [state : CompilerBuiltinIdsState]
  [index : i64]
  [value : i64]) : unit
  (array-set! (struct-get state ids) index value))

(define (compiler-builtin-ids-state-reset! [state : CompilerBuiltinIdsState]) : unit
  (compiler-builtin-ids-state-set-generation! state -1))

(define (compiler-builtin-ids-state-capture-from-globals!
  [state : CompilerBuiltinIdsState]) : unit
  (begin
    (compiler-builtin-ids-state-set-generation!
      state
      compiler-builtin-generation)
    (compiler-builtin-ids-state-set! state 0 compiler-builtin-id-tl-alloc)
    (compiler-builtin-ids-state-set! state 1 compiler-builtin-id-tl-region-mark)
    (compiler-builtin-ids-state-set!
      state
      2
      compiler-builtin-id-tl-region-reset)
    (compiler-builtin-ids-state-set! state 3 compiler-builtin-id-tl-arena-make)
    (compiler-builtin-ids-state-set!
      state
      4
      compiler-builtin-id-tl-arena-make-atomic)
    (compiler-builtin-ids-state-set!
      state
      5
      compiler-builtin-id-tl-arena-current)
    (compiler-builtin-ids-state-set! state 6 compiler-builtin-id-tl-arena-set)
    (compiler-builtin-ids-state-set!
      state
      7
      compiler-builtin-id-tl-arena-destroy)
    (compiler-builtin-ids-state-set!
      state
      8
      compiler-builtin-id-tl-arena-poison-enable)
    (compiler-builtin-ids-state-set!
      state
      9
      compiler-builtin-id-tl-thread-entry-ptr)
    (compiler-builtin-ids-state-set!
      state
      10
      compiler-builtin-id-tl-thread-init)
    (compiler-builtin-ids-state-set!
      state
      11
      compiler-builtin-id-tl-atomic-i64-load-ptr)
    (compiler-builtin-ids-state-set!
      state
      12
      compiler-builtin-id-tl-atomic-i64-store-ptr)
    (compiler-builtin-ids-state-set!
      state
      13
      compiler-builtin-id-tl-atomic-i64-add-ptr)
    (compiler-builtin-ids-state-set!
      state
      14
      compiler-builtin-id-tl-atomic-i64-fetch-add-ptr)
    (compiler-builtin-ids-state-set!
      state
      15
      compiler-builtin-id-tl-atomic-i32-load-ptr)
    (compiler-builtin-ids-state-set!
      state
      16
      compiler-builtin-id-tl-atomic-i32-store-ptr)
    (compiler-builtin-ids-state-set!
      state
      17
      compiler-builtin-id-tl-atomic-i32-add-ptr)
    (compiler-builtin-ids-state-set!
      state
      18
      compiler-builtin-id-tl-atomic-i32-fetch-add-ptr)
    (compiler-builtin-ids-state-set!
      state
      19
      compiler-builtin-id-tl-profile-alloc-total)
    (compiler-builtin-ids-state-set!
      state
      20
      compiler-builtin-id-tl-profile-alloc-live)
    (compiler-builtin-ids-state-set!
      state
      21
      compiler-builtin-id-tl-profile-alloc-peak)
    (compiler-builtin-ids-state-set!
      state
      22
      compiler-builtin-id-tl-profile-alloc-reset-peak)
    (compiler-builtin-ids-state-set! state 23 compiler-builtin-id-tl-substring)
    (compiler-builtin-ids-state-set! state 24 compiler-builtin-id-tl-str-view)
    (compiler-builtin-ids-state-set!
      state
      25
      compiler-builtin-id-tl-string-concat)
    (compiler-builtin-ids-state-set!
      state
      26
      compiler-builtin-id-tl-string-concat3)
    (compiler-builtin-ids-state-set!
      state
      27
      compiler-builtin-id-tl-string-concat4)
    (compiler-builtin-ids-state-set!
      state
      28
      compiler-builtin-id-tl-string-concat5)
    (compiler-builtin-ids-state-set! state 29 compiler-builtin-id-tl-string-eq)
    (compiler-builtin-ids-state-set!
      state
      30
      compiler-builtin-id-tl-string-to-int)
    (compiler-builtin-ids-state-set!
      state
      31
      compiler-builtin-id-tl-int-to-string)
    (compiler-builtin-ids-state-set!
      state
      32
      compiler-builtin-id-tl-hash-string)
    (compiler-builtin-ids-state-set!
      state
      33
      compiler-builtin-id-tl-env-var-exists)
    (compiler-builtin-ids-state-set!
      state
      34
      compiler-builtin-id-tl-env-var-value)
    (compiler-builtin-ids-state-set!
      state
      35
      compiler-builtin-id-env-path-separator)
    (compiler-builtin-ids-state-set! state 36 compiler-builtin-id-tl-oob-abort)
    (compiler-builtin-ids-state-set!
      state
      37
      compiler-builtin-id-tl-abort-label)
    (compiler-builtin-ids-state-set! state 38 compiler-builtin-id-tl-div-abort)
    (compiler-builtin-ids-state-set!
      state
      39
      compiler-builtin-id-tl-shift-abort)
    (compiler-builtin-ids-state-set!
      state
      40
      compiler-builtin-id-tl-array-fill8)
    (compiler-builtin-ids-state-set! state 41 compiler-builtin-id-tl-array-zero)
    (compiler-builtin-ids-state-set! state 42 compiler-builtin-id-tl-print-char)
    (compiler-builtin-ids-state-set! state 43 compiler-builtin-id-tl-print-f64)
    (compiler-builtin-ids-state-set! state 44 compiler-builtin-id-string-length)
    (compiler-builtin-ids-state-set! state 45 compiler-builtin-id-length)
    (compiler-builtin-ids-state-set! state 46 compiler-builtin-id-string-eq)
    (compiler-builtin-ids-state-set!
      state
      47
      compiler-builtin-id-string-eq-question)
    (compiler-builtin-ids-state-set! state 48 compiler-builtin-id-string-to-int)
    (compiler-builtin-ids-state-set! state 49 compiler-builtin-id-string-ref)
    (compiler-builtin-ids-state-set! state 50 compiler-builtin-id-char-at)
    (compiler-builtin-ids-state-set! state 51 compiler-builtin-id-array-length)
    (compiler-builtin-ids-state-set! state 52 compiler-builtin-id-cpuid)
    (compiler-builtin-ids-state-set! state 53 compiler-builtin-id-xgetbv)
    (compiler-builtin-ids-state-set! state 54 compiler-builtin-id-clone)
    (compiler-builtin-ids-state-set! state 55 compiler-builtin-id-arena-make)
    (compiler-builtin-ids-state-set!
      state
      56
      compiler-builtin-id-arena-make-atomic)
    (compiler-builtin-ids-state-set! state 57 compiler-builtin-id-arena-current)
    (compiler-builtin-ids-state-set! state 58 compiler-builtin-id-arena-mark)
    (compiler-builtin-ids-state-set!
      state
      59
      compiler-builtin-id-arena-set-bang)
    (compiler-builtin-ids-state-set! state 60 compiler-builtin-id-arena-destroy)
    (compiler-builtin-ids-state-set! state 61 compiler-builtin-id-arena-rewind)
    (compiler-builtin-ids-state-set!
      state
      62
      compiler-builtin-id-tl-atomic-i64-cas-ptr)
    (compiler-builtin-ids-state-set!
      state
      63
      compiler-builtin-id-tl-atomic-i32-cas-ptr)))

(define (compiler-builtin-ids-state-capture) : CompilerBuiltinIdsState
  (let
    [state : CompilerBuiltinIdsState (compiler-builtin-ids-state-new)]
    (begin
      (compiler-builtin-ids-state-capture-from-globals! state)
      state)))

(define (compiler-builtin-ids-state-install! [state : CompilerBuiltinIdsState]) : unit
  (begin
    (set!
      compiler-builtin-generation
      (compiler-builtin-ids-state-generation state))
    (set! compiler-builtin-id-tl-alloc (compiler-builtin-ids-state-ref state 0))
    (set!
      compiler-builtin-id-tl-region-mark
      (compiler-builtin-ids-state-ref state 1))
    (set!
      compiler-builtin-id-tl-region-reset
      (compiler-builtin-ids-state-ref state 2))
    (set!
      compiler-builtin-id-tl-arena-make
      (compiler-builtin-ids-state-ref state 3))
    (set!
      compiler-builtin-id-tl-arena-make-atomic
      (compiler-builtin-ids-state-ref state 4))
    (set!
      compiler-builtin-id-tl-arena-current
      (compiler-builtin-ids-state-ref state 5))
    (set!
      compiler-builtin-id-tl-arena-set
      (compiler-builtin-ids-state-ref state 6))
    (set!
      compiler-builtin-id-tl-arena-destroy
      (compiler-builtin-ids-state-ref state 7))
    (set!
      compiler-builtin-id-tl-arena-poison-enable
      (compiler-builtin-ids-state-ref state 8))
    (set!
      compiler-builtin-id-tl-thread-entry-ptr
      (compiler-builtin-ids-state-ref state 9))
    (set!
      compiler-builtin-id-tl-thread-init
      (compiler-builtin-ids-state-ref state 10))
    (set!
      compiler-builtin-id-tl-atomic-i64-load-ptr
      (compiler-builtin-ids-state-ref state 11))
    (set!
      compiler-builtin-id-tl-atomic-i64-store-ptr
      (compiler-builtin-ids-state-ref state 12))
    (set!
      compiler-builtin-id-tl-atomic-i64-add-ptr
      (compiler-builtin-ids-state-ref state 13))
    (set!
      compiler-builtin-id-tl-atomic-i64-fetch-add-ptr
      (compiler-builtin-ids-state-ref state 14))
    (set!
      compiler-builtin-id-tl-atomic-i32-load-ptr
      (compiler-builtin-ids-state-ref state 15))
    (set!
      compiler-builtin-id-tl-atomic-i32-store-ptr
      (compiler-builtin-ids-state-ref state 16))
    (set!
      compiler-builtin-id-tl-atomic-i32-add-ptr
      (compiler-builtin-ids-state-ref state 17))
    (set!
      compiler-builtin-id-tl-atomic-i32-fetch-add-ptr
      (compiler-builtin-ids-state-ref state 18))
    (set!
      compiler-builtin-id-tl-profile-alloc-total
      (compiler-builtin-ids-state-ref state 19))
    (set!
      compiler-builtin-id-tl-profile-alloc-live
      (compiler-builtin-ids-state-ref state 20))
    (set!
      compiler-builtin-id-tl-profile-alloc-peak
      (compiler-builtin-ids-state-ref state 21))
    (set!
      compiler-builtin-id-tl-profile-alloc-reset-peak
      (compiler-builtin-ids-state-ref state 22))
    (set!
      compiler-builtin-id-tl-substring
      (compiler-builtin-ids-state-ref state 23))
    (set!
      compiler-builtin-id-tl-str-view
      (compiler-builtin-ids-state-ref state 24))
    (set!
      compiler-builtin-id-tl-string-concat
      (compiler-builtin-ids-state-ref state 25))
    (set!
      compiler-builtin-id-tl-string-concat3
      (compiler-builtin-ids-state-ref state 26))
    (set!
      compiler-builtin-id-tl-string-concat4
      (compiler-builtin-ids-state-ref state 27))
    (set!
      compiler-builtin-id-tl-string-concat5
      (compiler-builtin-ids-state-ref state 28))
    (set!
      compiler-builtin-id-tl-string-eq
      (compiler-builtin-ids-state-ref state 29))
    (set!
      compiler-builtin-id-tl-string-to-int
      (compiler-builtin-ids-state-ref state 30))
    (set!
      compiler-builtin-id-tl-int-to-string
      (compiler-builtin-ids-state-ref state 31))
    (set!
      compiler-builtin-id-tl-hash-string
      (compiler-builtin-ids-state-ref state 32))
    (set!
      compiler-builtin-id-tl-env-var-exists
      (compiler-builtin-ids-state-ref state 33))
    (set!
      compiler-builtin-id-tl-env-var-value
      (compiler-builtin-ids-state-ref state 34))
    (set!
      compiler-builtin-id-env-path-separator
      (compiler-builtin-ids-state-ref state 35))
    (set!
      compiler-builtin-id-tl-oob-abort
      (compiler-builtin-ids-state-ref state 36))
    (set!
      compiler-builtin-id-tl-abort-label
      (compiler-builtin-ids-state-ref state 37))
    (set!
      compiler-builtin-id-tl-div-abort
      (compiler-builtin-ids-state-ref state 38))
    (set!
      compiler-builtin-id-tl-shift-abort
      (compiler-builtin-ids-state-ref state 39))
    (set!
      compiler-builtin-id-tl-array-fill8
      (compiler-builtin-ids-state-ref state 40))
    (set!
      compiler-builtin-id-tl-array-zero
      (compiler-builtin-ids-state-ref state 41))
    (set!
      compiler-builtin-id-tl-print-char
      (compiler-builtin-ids-state-ref state 42))
    (set!
      compiler-builtin-id-tl-print-f64
      (compiler-builtin-ids-state-ref state 43))
    (set!
      compiler-builtin-id-string-length
      (compiler-builtin-ids-state-ref state 44))
    (set! compiler-builtin-id-length (compiler-builtin-ids-state-ref state 45))
    (set!
      compiler-builtin-id-string-eq
      (compiler-builtin-ids-state-ref state 46))
    (set!
      compiler-builtin-id-string-eq-question
      (compiler-builtin-ids-state-ref state 47))
    (set!
      compiler-builtin-id-string-to-int
      (compiler-builtin-ids-state-ref state 48))
    (set!
      compiler-builtin-id-string-ref
      (compiler-builtin-ids-state-ref state 49))
    (set! compiler-builtin-id-char-at (compiler-builtin-ids-state-ref state 50))
    (set!
      compiler-builtin-id-array-length
      (compiler-builtin-ids-state-ref state 51))
    (set! compiler-builtin-id-cpuid (compiler-builtin-ids-state-ref state 52))
    (set! compiler-builtin-id-xgetbv (compiler-builtin-ids-state-ref state 53))
    (set! compiler-builtin-id-clone (compiler-builtin-ids-state-ref state 54))
    (set!
      compiler-builtin-id-arena-make
      (compiler-builtin-ids-state-ref state 55))
    (set!
      compiler-builtin-id-arena-make-atomic
      (compiler-builtin-ids-state-ref state 56))
    (set!
      compiler-builtin-id-arena-current
      (compiler-builtin-ids-state-ref state 57))
    (set!
      compiler-builtin-id-arena-mark
      (compiler-builtin-ids-state-ref state 58))
    (set!
      compiler-builtin-id-arena-set-bang
      (compiler-builtin-ids-state-ref state 59))
    (set!
      compiler-builtin-id-arena-destroy
      (compiler-builtin-ids-state-ref state 60))
    (set!
      compiler-builtin-id-arena-rewind
      (compiler-builtin-ids-state-ref state 61))
    (set!
      compiler-builtin-id-tl-atomic-i64-cas-ptr
      (compiler-builtin-ids-state-ref state 62))
    (set!
      compiler-builtin-id-tl-atomic-i32-cas-ptr
      (compiler-builtin-ids-state-ref state 63))))

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
      (set!
        compiler-builtin-id-tl-arena-make-atomic
        (intern "tl_arena_make_atomic"))
      (set! compiler-builtin-id-tl-arena-current (intern "tl_arena_current"))
      (set! compiler-builtin-id-tl-arena-set (intern "tl_arena_set"))
      (set! compiler-builtin-id-tl-arena-destroy (intern "tl_arena_destroy"))
      (set!
        compiler-builtin-id-tl-arena-poison-enable
        (intern "tl_arena_poison_enable"))
      (set!
        compiler-builtin-id-tl-thread-entry-ptr
        (intern "tl_thread_entry_ptr"))
      (set! compiler-builtin-id-tl-thread-init (intern "tl_thread_init"))
      (set!
        compiler-builtin-id-tl-atomic-i64-load-ptr
        (intern "tl_atomic_i64_load_ptr"))
      (set!
        compiler-builtin-id-tl-atomic-i64-store-ptr
        (intern "tl_atomic_i64_store_ptr"))
      (set!
        compiler-builtin-id-tl-atomic-i64-add-ptr
        (intern "tl_atomic_i64_add_ptr"))
      (set!
        compiler-builtin-id-tl-atomic-i64-fetch-add-ptr
        (intern "tl_atomic_i64_fetch_add_ptr"))
      (set!
        compiler-builtin-id-tl-atomic-i64-cas-ptr
        (intern "tl_atomic_i64_cas_ptr"))
      (set!
        compiler-builtin-id-tl-atomic-i32-load-ptr
        (intern "tl_atomic_i32_load_ptr"))
      (set!
        compiler-builtin-id-tl-atomic-i32-store-ptr
        (intern "tl_atomic_i32_store_ptr"))
      (set!
        compiler-builtin-id-tl-atomic-i32-add-ptr
        (intern "tl_atomic_i32_add_ptr"))
      (set!
        compiler-builtin-id-tl-atomic-i32-fetch-add-ptr
        (intern "tl_atomic_i32_fetch_add_ptr"))
      (set!
        compiler-builtin-id-tl-atomic-i32-cas-ptr
        (intern "tl_atomic_i32_cas_ptr"))
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
      (set! compiler-builtin-id-tl-str-view (intern "tl_str_view"))
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
      (set! compiler-builtin-id-tl-array-fill8 (intern "tl_array_fill8"))
      (set! compiler-builtin-id-tl-array-zero (intern "tl_array_zero"))
      (set! compiler-builtin-id-tl-print-char (intern "tl_print_char"))
      (set! compiler-builtin-id-tl-print-f64 (intern "tl_print_f64"))
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
      (set! compiler-builtin-id-arena-make-atomic (intern "arena-make-atomic"))
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
        compiler-builtin-id-tl-arena-make-atomic
        compiler-builtin-id-tl-arena-current
        compiler-builtin-id-tl-arena-set
        compiler-builtin-id-tl-arena-destroy)
      (compiler-builtin-id-any3?
        name-id
        compiler-builtin-id-tl-arena-poison-enable
        compiler-builtin-id-tl-thread-entry-ptr
        compiler-builtin-id-tl-thread-init)
      (compiler-builtin-id-any4?
        name-id
        compiler-builtin-id-tl-atomic-i64-load-ptr
        compiler-builtin-id-tl-atomic-i64-store-ptr
        compiler-builtin-id-tl-atomic-i64-add-ptr
        compiler-builtin-id-tl-atomic-i64-fetch-add-ptr)
      (compiler-builtin-id-any4?
        name-id
        compiler-builtin-id-tl-atomic-i32-load-ptr
        compiler-builtin-id-tl-atomic-i32-store-ptr
        compiler-builtin-id-tl-atomic-i32-add-ptr
        compiler-builtin-id-tl-atomic-i32-fetch-add-ptr)
      (compiler-builtin-id-any2?
        name-id
        compiler-builtin-id-tl-atomic-i64-cas-ptr
        compiler-builtin-id-tl-atomic-i32-cas-ptr))))

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
        compiler-builtin-id-tl-str-view
        compiler-builtin-id-tl-string-concat
        compiler-builtin-id-tl-string-concat3)
      (compiler-builtin-id-any4?
        name-id
        compiler-builtin-id-tl-string-concat4
        compiler-builtin-id-tl-string-concat5
        compiler-builtin-id-tl-int-to-string
        -1))))

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
    (compiler-builtin-backend-runtime-stdlib-ffi-id? name-id)
    (compiler-builtin-backend-runtime-stdlib-type-lisp-id? name-id)
    (compiler-builtin-backend-runtime-compatibility-alias-id? name-id)))

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
    (or
      (compiler-builtin-id-any4?
        name-id
        compiler-builtin-id-tl-arena-poison-enable
        compiler-builtin-id-tl-arena-make
        compiler-builtin-id-tl-arena-make-atomic
        compiler-builtin-id-tl-arena-current)
      (compiler-builtin-id-any3?
        name-id
        compiler-builtin-id-tl-arena-set
        compiler-builtin-id-tl-thread-entry-ptr
        compiler-builtin-id-tl-thread-init)
      (compiler-builtin-id-any4?
        name-id
        compiler-builtin-id-tl-atomic-i64-load-ptr
        compiler-builtin-id-tl-atomic-i64-store-ptr
        compiler-builtin-id-tl-atomic-i64-add-ptr
        compiler-builtin-id-tl-atomic-i64-fetch-add-ptr)
      (compiler-builtin-id-any4?
        name-id
        compiler-builtin-id-tl-atomic-i32-load-ptr
        compiler-builtin-id-tl-atomic-i32-store-ptr
        compiler-builtin-id-tl-atomic-i32-add-ptr
        compiler-builtin-id-tl-atomic-i32-fetch-add-ptr)
      (compiler-builtin-id-any2?
        name-id
        compiler-builtin-id-tl-atomic-i64-cas-ptr
        compiler-builtin-id-tl-atomic-i32-cas-ptr))))

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

(define (compiler-builtin-backend-tl-str-view-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tl-str-view)))

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

(define (compiler-builtin-backend-fixed-fault-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (or
      (compiler-builtin-id-any3?
        name-id
        compiler-builtin-id-tl-oob-abort
        compiler-builtin-id-tl-div-abort
        compiler-builtin-id-tl-shift-abort)
      (compiler-builtin-id-any2?
        name-id
        compiler-builtin-id-tl-array-fill8
        compiler-builtin-id-tl-array-zero))))

(define (compiler-builtin-backend-tl-array-fill8-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tl-array-fill8)))

(define (compiler-builtin-backend-tl-array-zero-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tl-array-zero)))

(define (compiler-builtin-backend-tl-print-char-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tl-print-char)))

(define (compiler-builtin-backend-tl-print-f64-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tl-print-f64)))

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
        compiler-builtin-id-arena-make-atomic
        compiler-builtin-id-arena-current
        compiler-builtin-id-arena-mark)
      (compiler-builtin-id-any3?
        name-id
        compiler-builtin-id-arena-set-bang
        compiler-builtin-id-arena-destroy
        compiler-builtin-id-arena-rewind))))

(define (compiler-builtin-lower-arena-nullary-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (compiler-builtin-id-any4?
      name-id
      compiler-builtin-id-arena-make
      compiler-builtin-id-arena-make-atomic
      compiler-builtin-id-arena-current
      compiler-builtin-id-arena-mark)))

(define (compiler-builtin-lower-arena-make-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-arena-make)))

(define (compiler-builtin-lower-arena-make-atomic-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-arena-make-atomic)))

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

(define (compiler-builtin-typecheck-string-length-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-string-length)))

(define (compiler-builtin-typecheck-array-length-id? [name-id : i64]) : bool
  (compiler-builtin-lower-array-length-id? name-id))

(define (compiler-builtin-typecheck-length-call-id? [name-id : i64]) : bool
  (compiler-builtin-lower-length-call-id? name-id))

(define (compiler-builtin-typecheck-string-ref-call-id? [name-id : i64]) : bool
  (compiler-builtin-lower-string-ref-call-id? name-id))

(define (compiler-builtin-typecheck-clone-id? [name-id : i64]) : bool
  (compiler-builtin-lower-clone-id? name-id))

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

(define (compiler-builtin-typecheck-string-eq-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (compiler-builtin-id-any2?
      name-id
      compiler-builtin-id-string-eq
      compiler-builtin-id-string-eq-question)))

(define (compiler-builtin-typecheck-string-to-int-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-string-to-int)))

(define (compiler-builtin-typecheck-borrowed-string-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (or
      (compiler-builtin-typecheck-string-eq-id? name-id)
      (compiler-builtin-typecheck-string-to-int-id? name-id))))