;; compiler_builtin_ids.tl - reset-aware intern ids for fixed compiler builtins.
(import compiler_intern as ci)

(define compiler-builtin-generation : i64
  -1)
(define compiler-builtin-pool-data-addr : i64
  -1)
(define compiler-builtin-pool-len : i64
  -1)
(define compiler-builtin-parse-initialized : bool
  false)
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
(define compiler-builtin-id-tl-private-string-length : i64
  -1)
(define compiler-builtin-id-tl-private-string-ref : i64
  -1)
(define compiler-builtin-id-tl-private-string-eq : i64
  -1)
(define compiler-builtin-id-tl-private-string-to-int : i64
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
(define compiler-builtin-id-eq : i64
  -1)
(define compiler-builtin-id-string-append : i64
  -1)
(define compiler-builtin-id-string-concat : i64
  -1)
(define compiler-builtin-id-string-to-int : i64
  -1)
(define compiler-builtin-id-string-ref : i64
  -1)
(define compiler-builtin-id-char-at : i64
  -1)
(define compiler-builtin-id-array-length : i64
  -1)
(define compiler-builtin-id-private-array-length : i64
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
(define compiler-builtin-id-tls-current-arena : i64
  -1)
(define compiler-builtin-id-tls-current-arena-set-bang : i64
  -1)
(define compiler-builtin-id-tl-tls-current-arena-load : i64
  -1)
(define compiler-builtin-id-tl-tls-current-arena-store : i64
  -1)
(define compiler-builtin-id-fix-empty : i64
  -1)
(define compiler-builtin-id-fix-dollar_lower_dot_precise_type_dce : i64
  -1)
(define compiler-builtin-id-fix-colon : i64
  -1)
(define compiler-builtin-id-fix-tl_unquote_set_target : i64
  -1)
(define compiler-builtin-id-fix-lt_ast_decl_list_fallback_gt : i64
  -1)
(define compiler-builtin-id-fix-acc : i64
  -1)
(define compiler-builtin-id-fix-alias : i64
  -1)
(define compiler-builtin-id-fix-arena_dot_Arena : i64
  -1)
(define compiler-builtin-id-fix-ArenaMark : i64
  -1)
(define compiler-builtin-id-fix-arm : i64
  -1)
(define compiler-builtin-id-fix-Box : i64
  -1)
(define compiler-builtin-id-fix-c : i64
  -1)
(define compiler-builtin-id-fix-callback_target : i64
  -1)
(define compiler-builtin-id-fix-Choice : i64
  -1)
(define compiler-builtin-id-fix-clone : i64
  -1)
(define compiler-builtin-id-fix-CloneShortList : i64
  -1)
(define compiler-builtin-id-fix-comptime : i64
  -1)
(define compiler-builtin-id-fix-comptime_dot_comptime_error : i64
  -1)
(define compiler-builtin-id-fix-comptime_dot_error : i64
  -1)
(define compiler-builtin-id-fix-comptime_slash_comptime_error : i64
  -1)
(define compiler-builtin-id-fix-comptime_slash_error : i64
  -1)
(define compiler-builtin-id-fix-comptime_error : i64
  -1)
(define compiler-builtin-id-fix-cond : i64
  -1)
(define compiler-builtin-id-fix-Cons : i64
  -1)
(define compiler-builtin-id-fix-count : i64
  -1)
(define compiler-builtin-id-fix-e : i64
  -1)
(define compiler-builtin-id-fix-else : i64
  -1)
(define compiler-builtin-id-fix-Expr : i64
  -1)
(define compiler-builtin-id-fix-ExprBindingClause : i64
  -1)
(define compiler-builtin-id-fix-ExprBindingClauseList : i64
  -1)
(define compiler-builtin-id-fix-ExprClause : i64
  -1)
(define compiler-builtin-id-fix-ExprClauseList : i64
  -1)
(define compiler-builtin-id-fix-ExprList : i64
  -1)
(define compiler-builtin-id-fix-Failed : i64
  -1)
(define compiler-builtin-id-fix-field : i64
  -1)
(define compiler-builtin-id-fix-flag : i64
  -1)
(define compiler-builtin-id-fix-h : i64
  -1)
(define compiler-builtin-id-fix-helper : i64
  -1)
(define compiler-builtin-id-fix-id : i64
  -1)
(define compiler-builtin-id-fix-import : i64
  -1)
(define compiler-builtin-id-fix-ImportedMark : i64
  -1)
(define compiler-builtin-id-fix-info : i64
  -1)
(define compiler-builtin-id-fix-input : i64
  -1)
(define compiler-builtin-id-fix-item : i64
  -1)
(define compiler-builtin-id-fix-items : i64
  -1)
(define compiler-builtin-id-fix-label : i64
  -1)
(define compiler-builtin-id-fix-left : i64
  -1)
(define compiler-builtin-id-fix-left_slash_same : i64
  -1)
(define compiler-builtin-id-fix-m : i64
  -1)
(define compiler-builtin-id-fix-macro_only_helper : i64
  -1)
(define compiler-builtin-id-fix-main : i64
  -1)
(define compiler-builtin-id-fix-MatchArm : i64
  -1)
(define compiler-builtin-id-fix-MatchArmList : i64
  -1)
(define compiler-builtin-id-fix-Maybe : i64
  -1)
(define compiler-builtin-id-fix-missing : i64
  -1)
(define compiler-builtin-id-fix-n : i64
  -1)
(define compiler-builtin-id-fix-name_cache_split_alias_3940 : i64
  -1)
(define compiler-builtin-id-fix-name_cache_split_value_3940 : i64
  -1)
(define compiler-builtin-id-fix-Nil : i64
  -1)
(define compiler-builtin-id-fix-Packet : i64
  -1)
(define compiler-builtin-id-fix-Pattern : i64
  -1)
(define compiler-builtin-id-fix-PatternList : i64
  -1)
(define compiler-builtin-id-fix-point : i64
  -1)
(define compiler-builtin-id-fix-Point : i64
  -1)
(define compiler-builtin-id-fix-Ready : i64
  -1)
(define compiler-builtin-id-fix-record : i64
  -1)
(define compiler-builtin-id-fix-Record : i64
  -1)
(define compiler-builtin-id-fix-Result : i64
  -1)
(define compiler-builtin-id-fix-ResultIoString : i64
  -1)
(define compiler-builtin-id-fix-right : i64
  -1)
(define compiler-builtin-id-fix-right_slash_Some : i64
  -1)
(define compiler-builtin-id-fix-same : i64
  -1)
(define compiler-builtin-id-fix-second : i64
  -1)
(define compiler-builtin-id-fix-Some : i64
  -1)
(define compiler-builtin-id-fix-Status : i64
  -1)
(define compiler-builtin-id-fix-stdlib : i64
  -1)
(define compiler-builtin-id-fix-stdlib_dot_comptime_dot_comptime_error : i64
  -1)
(define compiler-builtin-id-fix-stdlib_dot_comptime_dot_error : i64
  -1)
(define compiler-builtin-id-fix-stdlib_dot_comptime_slash_comptime_error : i64
  -1)
(define compiler-builtin-id-fix-stdlib_dot_comptime_slash_error : i64
  -1)
(define compiler-builtin-id-fix-stdlib_dot_comptime_slash_ExprBindingClause : i64
  -1)
(define compiler-builtin-id-fix-stdlib_dot_comptime_slash_ExprBindingClauseList : i64
  -1)
(define compiler-builtin-id-fix-stdlib_dot_comptime_slash_ExprClause : i64
  -1)
(define compiler-builtin-id-fix-stdlib_dot_comptime_slash_ExprClauseList : i64
  -1)
(define compiler-builtin-id-fix-stdlib_slash_comptime : i64
  -1)
(define compiler-builtin-id-fix-stdlib_slash_comptime_dot_comptime_error : i64
  -1)
(define compiler-builtin-id-fix-stdlib_slash_comptime_dot_error : i64
  -1)
(define compiler-builtin-id-fix-stdlib_slash_comptime_slash_comptime_error : i64
  -1)
(define compiler-builtin-id-fix-stdlib_slash_comptime_slash_error : i64
  -1)
(define compiler-builtin-id-fix-stdlib_slash_string : i64
  -1)
(define compiler-builtin-id-fix-string : i64
  -1)
(define compiler-builtin-id-fix-subject : i64
  -1)
(define compiler-builtin-id-fix-t : i64
  -1)
(define compiler-builtin-id-fix-T : i64
  -1)
(define compiler-builtin-id-fix-tag : i64
  -1)
(define compiler-builtin-id-fix-target : i64
  -1)
(define compiler-builtin-id-fix-ThreadBox : i64
  -1)
(define compiler-builtin-id-fix-type : i64
  -1)
(define compiler-builtin-id-fix-TypeInfoArray : i64
  -1)
(define compiler-builtin-id-fix-TypeInfoBuiltin : i64
  -1)
(define compiler-builtin-id-fix-TypeInfoDynArray : i64
  -1)
(define compiler-builtin-id-fix-TypeInfoEnum : i64
  -1)
(define compiler-builtin-id-fix-TypeInfoFunction : i64
  -1)
(define compiler-builtin-id-fix-TypeInfoStruct : i64
  -1)
(define compiler-builtin-id-fix-TypeInfoTuple : i64
  -1)
(define compiler-builtin-id-fix-U : i64
  -1)
(define compiler-builtin-id-fix-unquote : i64
  -1)
(define compiler-builtin-id-fix-UsedBox : i64
  -1)
(define compiler-builtin-id-fix-UsedEnum : i64
  -1)
(define compiler-builtin-id-fix-value : i64
  -1)
(define compiler-builtin-id-fix-x : i64
  -1)
(define compiler-builtin-id-fix-xs : i64
  -1)
(define compiler-builtin-id-fix-y : i64
  -1)
(define compiler-builtin-id-fix-module : i64
  -1)
(define compiler-builtin-id-fix-Module : i64
  -1)
(define compiler-builtin-id-fix-decls : i64
  -1)
(define compiler-builtin-id-fix-Decls : i64
  -1)
(define compiler-builtin-id-fix-expr : i64
  -1)
(define compiler-builtin-id-fix-lt_parse_ast_decl_vec_fallback_gt : i64
  -1)

(defstruct CompilerBuiltinIdsState
  (generation (Array i64))
  (ids (Array i64)))

(define (state-new) : CompilerBuiltinIdsState
  (let
    [generation : (Array i64) (make-array i64 1)]
    [ids : (Array i64) (make-array i64 195)]
    [i : i64 0]
    (begin
      (array-set! generation 0 -1)
      (while (< i 195)
        (begin
          (array-set! ids i -1)
          (set! i (+ i 1))))
      (CompilerBuiltinIdsState generation ids))))

(define (state-generation [state : CompilerBuiltinIdsState]) : i64
  (array-ref (struct-get state generation) 0))

(define (state-set-generation!
  [state : CompilerBuiltinIdsState]
  [generation : i64]) : unit
  (array-set! (struct-get state generation) 0 generation))

(define (state-ref [state : CompilerBuiltinIdsState] [index : i64]) : i64
  (array-ref (struct-get state ids) index))

(define (state-ids-data-addr [state : CompilerBuiltinIdsState]) : i64
  (cast
    (unsafe
      (ptr->int (ptr-cast (array-data (struct-get state ids)) : (Ptr u8))))
    : i64))

(define (state-set!
  [state : CompilerBuiltinIdsState]
  [index : i64]
  [value : i64]) : unit
  (array-set! (struct-get state ids) index value))

(define (state-reset! [state : CompilerBuiltinIdsState]) : unit
  (state-set-generation! state -1))

(define (state-capture-from-globals! [state : CompilerBuiltinIdsState]) : unit
  (begin
    (state-set-generation! state compiler-builtin-generation)
    (state-set! state 0 compiler-builtin-id-tl-alloc)
    (state-set! state 1 compiler-builtin-id-tl-region-mark)
    (state-set! state 2 compiler-builtin-id-tl-region-reset)
    (state-set! state 3 compiler-builtin-id-tl-arena-make)
    (state-set! state 4 compiler-builtin-id-tl-arena-make-atomic)
    (state-set! state 5 compiler-builtin-id-tl-arena-current)
    (state-set! state 6 compiler-builtin-id-tl-arena-set)
    (state-set! state 7 compiler-builtin-id-tl-arena-destroy)
    (state-set! state 8 compiler-builtin-id-tl-arena-poison-enable)
    (state-set! state 9 compiler-builtin-id-tl-thread-entry-ptr)
    (state-set! state 10 compiler-builtin-id-tl-thread-init)
    (state-set! state 11 compiler-builtin-id-tl-atomic-i64-load-ptr)
    (state-set! state 12 compiler-builtin-id-tl-atomic-i64-store-ptr)
    (state-set! state 13 compiler-builtin-id-tl-atomic-i64-add-ptr)
    (state-set! state 14 compiler-builtin-id-tl-atomic-i64-fetch-add-ptr)
    (state-set! state 15 compiler-builtin-id-tl-atomic-i32-load-ptr)
    (state-set! state 16 compiler-builtin-id-tl-atomic-i32-store-ptr)
    (state-set! state 17 compiler-builtin-id-tl-atomic-i32-add-ptr)
    (state-set! state 18 compiler-builtin-id-tl-atomic-i32-fetch-add-ptr)
    (state-set! state 19 compiler-builtin-id-tl-profile-alloc-total)
    (state-set! state 20 compiler-builtin-id-tl-profile-alloc-live)
    (state-set! state 21 compiler-builtin-id-tl-profile-alloc-peak)
    (state-set! state 22 compiler-builtin-id-tl-profile-alloc-reset-peak)
    (state-set! state 23 compiler-builtin-id-tl-substring)
    (state-set! state 24 compiler-builtin-id-tl-str-view)
    (state-set! state 25 compiler-builtin-id-tl-string-concat)
    (state-set! state 26 compiler-builtin-id-tl-string-concat3)
    (state-set! state 27 compiler-builtin-id-tl-string-concat4)
    (state-set! state 28 compiler-builtin-id-tl-string-concat5)
    (state-set! state 29 compiler-builtin-id-tl-string-eq)
    (state-set! state 30 compiler-builtin-id-tl-string-to-int)
    (state-set! state 31 compiler-builtin-id-tl-int-to-string)
    (state-set! state 32 compiler-builtin-id-tl-hash-string)
    (state-set! state 33 compiler-builtin-id-tl-env-var-exists)
    (state-set! state 34 compiler-builtin-id-tl-env-var-value)
    (state-set! state 35 compiler-builtin-id-env-path-separator)
    (state-set! state 36 compiler-builtin-id-tl-oob-abort)
    (state-set! state 37 compiler-builtin-id-tl-abort-label)
    (state-set! state 38 compiler-builtin-id-tl-div-abort)
    (state-set! state 39 compiler-builtin-id-tl-shift-abort)
    (state-set! state 40 compiler-builtin-id-tl-array-fill8)
    (state-set! state 41 compiler-builtin-id-tl-array-zero)
    (state-set! state 42 compiler-builtin-id-tl-print-char)
    (state-set! state 43 compiler-builtin-id-tl-print-f64)
    (state-set! state 44 compiler-builtin-id-string-length)
    (state-set! state 45 compiler-builtin-id-length)
    (state-set! state 46 compiler-builtin-id-string-eq)
    (state-set! state 47 compiler-builtin-id-string-eq-question)
    (state-set! state 48 compiler-builtin-id-string-to-int)
    (state-set! state 49 compiler-builtin-id-string-ref)
    (state-set! state 50 compiler-builtin-id-char-at)
    (state-set! state 51 compiler-builtin-id-array-length)
    (state-set! state 52 compiler-builtin-id-cpuid)
    (state-set! state 53 compiler-builtin-id-xgetbv)
    (state-set! state 54 compiler-builtin-id-clone)
    (state-set! state 55 compiler-builtin-id-arena-make)
    (state-set! state 56 compiler-builtin-id-arena-make-atomic)
    (state-set! state 57 compiler-builtin-id-arena-current)
    (state-set! state 58 compiler-builtin-id-arena-mark)
    (state-set! state 59 compiler-builtin-id-arena-set-bang)
    (state-set! state 60 compiler-builtin-id-arena-destroy)
    (state-set! state 61 compiler-builtin-id-arena-rewind)
    (state-set! state 62 compiler-builtin-id-tl-atomic-i64-cas-ptr)
    (state-set! state 63 compiler-builtin-id-tl-atomic-i32-cas-ptr)
    (state-set! state 64 compiler-builtin-id-private-array-length)
    (state-set! state 65 compiler-builtin-id-tl-private-string-length)
    (state-set! state 66 compiler-builtin-id-tl-private-string-ref)
    (state-set! state 67 compiler-builtin-id-tl-private-string-eq)
    (state-set! state 68 compiler-builtin-id-tl-private-string-to-int)
    (state-set! state 69 compiler-builtin-id-tls-current-arena)
    (state-set! state 70 compiler-builtin-id-tls-current-arena-set-bang)
    (state-set! state 71 compiler-builtin-id-tl-tls-current-arena-load)
    (state-set! state 72 compiler-builtin-id-tl-tls-current-arena-store)
    (state-set! state 73 compiler-builtin-id-fix-empty)
    (state-set!
      state
      74
      compiler-builtin-id-fix-dollar_lower_dot_precise_type_dce)
    (state-set! state 75 compiler-builtin-id-fix-colon)
    (state-set! state 76 compiler-builtin-id-fix-tl_unquote_set_target)
    (state-set! state 77 compiler-builtin-id-fix-lt_ast_decl_list_fallback_gt)
    (state-set! state 78 compiler-builtin-id-fix-acc)
    (state-set! state 79 compiler-builtin-id-fix-alias)
    (state-set! state 80 compiler-builtin-id-fix-arena_dot_Arena)
    (state-set! state 81 compiler-builtin-id-fix-ArenaMark)
    (state-set! state 82 compiler-builtin-id-fix-arm)
    (state-set! state 83 compiler-builtin-id-fix-Box)
    (state-set! state 84 compiler-builtin-id-fix-c)
    (state-set! state 85 compiler-builtin-id-fix-callback_target)
    (state-set! state 86 compiler-builtin-id-fix-Choice)
    (state-set! state 87 compiler-builtin-id-fix-clone)
    (state-set! state 88 compiler-builtin-id-fix-CloneShortList)
    (state-set! state 89 compiler-builtin-id-fix-comptime)
    (state-set! state 90 compiler-builtin-id-fix-comptime_dot_comptime_error)
    (state-set! state 91 compiler-builtin-id-fix-comptime_dot_error)
    (state-set! state 92 compiler-builtin-id-fix-comptime_slash_comptime_error)
    (state-set! state 93 compiler-builtin-id-fix-comptime_slash_error)
    (state-set! state 94 compiler-builtin-id-fix-comptime_error)
    (state-set! state 95 compiler-builtin-id-fix-cond)
    (state-set! state 96 compiler-builtin-id-fix-Cons)
    (state-set! state 97 compiler-builtin-id-fix-count)
    (state-set! state 98 compiler-builtin-id-fix-e)
    (state-set! state 99 compiler-builtin-id-fix-else)
    (state-set! state 100 compiler-builtin-id-fix-Expr)
    (state-set! state 101 compiler-builtin-id-fix-ExprBindingClause)
    (state-set! state 102 compiler-builtin-id-fix-ExprBindingClauseList)
    (state-set! state 103 compiler-builtin-id-fix-ExprClause)
    (state-set! state 104 compiler-builtin-id-fix-ExprClauseList)
    (state-set! state 105 compiler-builtin-id-fix-ExprList)
    (state-set! state 106 compiler-builtin-id-fix-Failed)
    (state-set! state 107 compiler-builtin-id-fix-field)
    (state-set! state 108 compiler-builtin-id-fix-flag)
    (state-set! state 109 compiler-builtin-id-fix-h)
    (state-set! state 110 compiler-builtin-id-fix-helper)
    (state-set! state 111 compiler-builtin-id-fix-id)
    (state-set! state 112 compiler-builtin-id-fix-import)
    (state-set! state 113 compiler-builtin-id-fix-ImportedMark)
    (state-set! state 114 compiler-builtin-id-fix-info)
    (state-set! state 115 compiler-builtin-id-fix-input)
    (state-set! state 116 compiler-builtin-id-fix-item)
    (state-set! state 117 compiler-builtin-id-fix-items)
    (state-set! state 118 compiler-builtin-id-fix-label)
    (state-set! state 119 compiler-builtin-id-fix-left)
    (state-set! state 120 compiler-builtin-id-fix-left_slash_same)
    (state-set! state 121 compiler-builtin-id-fix-m)
    (state-set! state 122 compiler-builtin-id-fix-macro_only_helper)
    (state-set! state 123 compiler-builtin-id-fix-main)
    (state-set! state 124 compiler-builtin-id-fix-MatchArm)
    (state-set! state 125 compiler-builtin-id-fix-MatchArmList)
    (state-set! state 126 compiler-builtin-id-fix-Maybe)
    (state-set! state 127 compiler-builtin-id-fix-missing)
    (state-set! state 128 compiler-builtin-id-fix-n)
    (state-set! state 129 compiler-builtin-id-fix-name_cache_split_alias_3940)
    (state-set! state 130 compiler-builtin-id-fix-name_cache_split_value_3940)
    (state-set! state 131 compiler-builtin-id-fix-Nil)
    (state-set! state 132 compiler-builtin-id-fix-Packet)
    (state-set! state 133 compiler-builtin-id-fix-Pattern)
    (state-set! state 134 compiler-builtin-id-fix-PatternList)
    (state-set! state 135 compiler-builtin-id-fix-point)
    (state-set! state 136 compiler-builtin-id-fix-Point)
    (state-set! state 137 compiler-builtin-id-fix-Ready)
    (state-set! state 138 compiler-builtin-id-fix-record)
    (state-set! state 139 compiler-builtin-id-fix-Record)
    (state-set! state 140 compiler-builtin-id-fix-Result)
    (state-set! state 141 compiler-builtin-id-fix-ResultIoString)
    (state-set! state 142 compiler-builtin-id-fix-right)
    (state-set! state 143 compiler-builtin-id-fix-right_slash_Some)
    (state-set! state 144 compiler-builtin-id-fix-same)
    (state-set! state 145 compiler-builtin-id-fix-second)
    (state-set! state 146 compiler-builtin-id-fix-Some)
    (state-set! state 147 compiler-builtin-id-fix-Status)
    (state-set! state 148 compiler-builtin-id-fix-stdlib)
    (state-set!
      state
      149
      compiler-builtin-id-fix-stdlib_dot_comptime_dot_comptime_error)
    (state-set! state 150 compiler-builtin-id-fix-stdlib_dot_comptime_dot_error)
    (state-set!
      state
      151
      compiler-builtin-id-fix-stdlib_dot_comptime_slash_comptime_error)
    (state-set!
      state
      152
      compiler-builtin-id-fix-stdlib_dot_comptime_slash_error)
    (state-set!
      state
      153
      compiler-builtin-id-fix-stdlib_dot_comptime_slash_ExprBindingClause)
    (state-set!
      state
      154
      compiler-builtin-id-fix-stdlib_dot_comptime_slash_ExprBindingClauseList)
    (state-set!
      state
      155
      compiler-builtin-id-fix-stdlib_dot_comptime_slash_ExprClause)
    (state-set!
      state
      156
      compiler-builtin-id-fix-stdlib_dot_comptime_slash_ExprClauseList)
    (state-set! state 157 compiler-builtin-id-fix-stdlib_slash_comptime)
    (state-set!
      state
      158
      compiler-builtin-id-fix-stdlib_slash_comptime_dot_comptime_error)
    (state-set!
      state
      159
      compiler-builtin-id-fix-stdlib_slash_comptime_dot_error)
    (state-set!
      state
      160
      compiler-builtin-id-fix-stdlib_slash_comptime_slash_comptime_error)
    (state-set!
      state
      161
      compiler-builtin-id-fix-stdlib_slash_comptime_slash_error)
    (state-set! state 162 compiler-builtin-id-fix-stdlib_slash_string)
    (state-set! state 163 compiler-builtin-id-fix-string)
    (state-set! state 164 compiler-builtin-id-fix-subject)
    (state-set! state 165 compiler-builtin-id-fix-t)
    (state-set! state 166 compiler-builtin-id-fix-T)
    (state-set! state 167 compiler-builtin-id-fix-tag)
    (state-set! state 168 compiler-builtin-id-fix-target)
    (state-set! state 169 compiler-builtin-id-fix-ThreadBox)
    (state-set! state 170 compiler-builtin-id-fix-type)
    (state-set! state 171 compiler-builtin-id-fix-TypeInfoArray)
    (state-set! state 172 compiler-builtin-id-fix-TypeInfoBuiltin)
    (state-set! state 173 compiler-builtin-id-fix-TypeInfoDynArray)
    (state-set! state 174 compiler-builtin-id-fix-TypeInfoEnum)
    (state-set! state 175 compiler-builtin-id-fix-TypeInfoFunction)
    (state-set! state 176 compiler-builtin-id-fix-TypeInfoStruct)
    (state-set! state 177 compiler-builtin-id-fix-TypeInfoTuple)
    (state-set! state 178 compiler-builtin-id-fix-U)
    (state-set! state 179 compiler-builtin-id-fix-unquote)
    (state-set! state 180 compiler-builtin-id-fix-UsedBox)
    (state-set! state 181 compiler-builtin-id-fix-UsedEnum)
    (state-set! state 182 compiler-builtin-id-fix-value)
    (state-set! state 183 compiler-builtin-id-fix-x)
    (state-set! state 184 compiler-builtin-id-fix-xs)
    (state-set! state 185 compiler-builtin-id-fix-y)
    (state-set! state 186 compiler-builtin-id-fix-module)
    (state-set! state 187 compiler-builtin-id-fix-Module)
    (state-set! state 188 compiler-builtin-id-fix-decls)
    (state-set! state 189 compiler-builtin-id-fix-Decls)
    (state-set! state 190 compiler-builtin-id-fix-expr)
    (state-set!
      state
      191
      compiler-builtin-id-fix-lt_parse_ast_decl_vec_fallback_gt)
    (state-set! state 192 compiler-builtin-id-eq)
    (state-set! state 193 compiler-builtin-id-string-append)
    (state-set! state 194 compiler-builtin-id-string-concat)))

(define (state-capture) : CompilerBuiltinIdsState
  (let
    [state : CompilerBuiltinIdsState (state-new)]
    (begin
      (state-capture-from-globals! state)
      state)))

(define (state-install! [state : CompilerBuiltinIdsState]) : unit
  (begin
    (set! compiler-builtin-generation (state-generation state))
    (set! compiler-builtin-id-tl-alloc (state-ref state 0))
    (set! compiler-builtin-id-tl-region-mark (state-ref state 1))
    (set! compiler-builtin-id-tl-region-reset (state-ref state 2))
    (set! compiler-builtin-id-tl-arena-make (state-ref state 3))
    (set! compiler-builtin-id-tl-arena-make-atomic (state-ref state 4))
    (set! compiler-builtin-id-tl-arena-current (state-ref state 5))
    (set! compiler-builtin-id-tl-arena-set (state-ref state 6))
    (set! compiler-builtin-id-tl-arena-destroy (state-ref state 7))
    (set! compiler-builtin-id-tl-arena-poison-enable (state-ref state 8))
    (set! compiler-builtin-id-tl-thread-entry-ptr (state-ref state 9))
    (set! compiler-builtin-id-tl-thread-init (state-ref state 10))
    (set! compiler-builtin-id-tl-atomic-i64-load-ptr (state-ref state 11))
    (set! compiler-builtin-id-tl-atomic-i64-store-ptr (state-ref state 12))
    (set! compiler-builtin-id-tl-atomic-i64-add-ptr (state-ref state 13))
    (set! compiler-builtin-id-tl-atomic-i64-fetch-add-ptr (state-ref state 14))
    (set! compiler-builtin-id-tl-atomic-i32-load-ptr (state-ref state 15))
    (set! compiler-builtin-id-tl-atomic-i32-store-ptr (state-ref state 16))
    (set! compiler-builtin-id-tl-atomic-i32-add-ptr (state-ref state 17))
    (set! compiler-builtin-id-tl-atomic-i32-fetch-add-ptr (state-ref state 18))
    (set! compiler-builtin-id-tl-profile-alloc-total (state-ref state 19))
    (set! compiler-builtin-id-tl-profile-alloc-live (state-ref state 20))
    (set! compiler-builtin-id-tl-profile-alloc-peak (state-ref state 21))
    (set! compiler-builtin-id-tl-profile-alloc-reset-peak (state-ref state 22))
    (set! compiler-builtin-id-tl-substring (state-ref state 23))
    (set! compiler-builtin-id-tl-str-view (state-ref state 24))
    (set! compiler-builtin-id-tl-string-concat (state-ref state 25))
    (set! compiler-builtin-id-tl-string-concat3 (state-ref state 26))
    (set! compiler-builtin-id-tl-string-concat4 (state-ref state 27))
    (set! compiler-builtin-id-tl-string-concat5 (state-ref state 28))
    (set! compiler-builtin-id-tl-string-eq (state-ref state 29))
    (set! compiler-builtin-id-tl-string-to-int (state-ref state 30))
    (set! compiler-builtin-id-tl-int-to-string (state-ref state 31))
    (set! compiler-builtin-id-tl-hash-string (state-ref state 32))
    (set! compiler-builtin-id-tl-env-var-exists (state-ref state 33))
    (set! compiler-builtin-id-tl-env-var-value (state-ref state 34))
    (set! compiler-builtin-id-env-path-separator (state-ref state 35))
    (set! compiler-builtin-id-tl-oob-abort (state-ref state 36))
    (set! compiler-builtin-id-tl-abort-label (state-ref state 37))
    (set! compiler-builtin-id-tl-div-abort (state-ref state 38))
    (set! compiler-builtin-id-tl-shift-abort (state-ref state 39))
    (set! compiler-builtin-id-tl-array-fill8 (state-ref state 40))
    (set! compiler-builtin-id-tl-array-zero (state-ref state 41))
    (set! compiler-builtin-id-tl-print-char (state-ref state 42))
    (set! compiler-builtin-id-tl-print-f64 (state-ref state 43))
    (set! compiler-builtin-id-string-length (state-ref state 44))
    (set! compiler-builtin-id-length (state-ref state 45))
    (set! compiler-builtin-id-string-eq (state-ref state 46))
    (set! compiler-builtin-id-string-eq-question (state-ref state 47))
    (set! compiler-builtin-id-string-to-int (state-ref state 48))
    (set! compiler-builtin-id-string-ref (state-ref state 49))
    (set! compiler-builtin-id-char-at (state-ref state 50))
    (set! compiler-builtin-id-array-length (state-ref state 51))
    (set! compiler-builtin-id-cpuid (state-ref state 52))
    (set! compiler-builtin-id-xgetbv (state-ref state 53))
    (set! compiler-builtin-id-clone (state-ref state 54))
    (set! compiler-builtin-id-arena-make (state-ref state 55))
    (set! compiler-builtin-id-arena-make-atomic (state-ref state 56))
    (set! compiler-builtin-id-arena-current (state-ref state 57))
    (set! compiler-builtin-id-arena-mark (state-ref state 58))
    (set! compiler-builtin-id-arena-set-bang (state-ref state 59))
    (set! compiler-builtin-id-arena-destroy (state-ref state 60))
    (set! compiler-builtin-id-arena-rewind (state-ref state 61))
    (set! compiler-builtin-id-tl-atomic-i64-cas-ptr (state-ref state 62))
    (set! compiler-builtin-id-tl-atomic-i32-cas-ptr (state-ref state 63))
    (set! compiler-builtin-id-private-array-length (state-ref state 64))
    (set! compiler-builtin-id-tl-private-string-length (state-ref state 65))
    (set! compiler-builtin-id-tl-private-string-ref (state-ref state 66))
    (set! compiler-builtin-id-tl-private-string-eq (state-ref state 67))
    (set! compiler-builtin-id-tl-private-string-to-int (state-ref state 68))
    (set! compiler-builtin-id-tls-current-arena (state-ref state 69))
    (set! compiler-builtin-id-tls-current-arena-set-bang (state-ref state 70))
    (set! compiler-builtin-id-tl-tls-current-arena-load (state-ref state 71))
    (set! compiler-builtin-id-tl-tls-current-arena-store (state-ref state 72))
    (set! compiler-builtin-id-fix-empty (state-ref state 73))
    (set!
      compiler-builtin-id-fix-dollar_lower_dot_precise_type_dce
      (state-ref state 74))
    (set! compiler-builtin-id-fix-colon (state-ref state 75))
    (set! compiler-builtin-id-fix-tl_unquote_set_target (state-ref state 76))
    (set!
      compiler-builtin-id-fix-lt_ast_decl_list_fallback_gt
      (state-ref state 77))
    (set! compiler-builtin-id-fix-acc (state-ref state 78))
    (set! compiler-builtin-id-fix-alias (state-ref state 79))
    (set! compiler-builtin-id-fix-arena_dot_Arena (state-ref state 80))
    (set! compiler-builtin-id-fix-ArenaMark (state-ref state 81))
    (set! compiler-builtin-id-fix-arm (state-ref state 82))
    (set! compiler-builtin-id-fix-Box (state-ref state 83))
    (set! compiler-builtin-id-fix-c (state-ref state 84))
    (set! compiler-builtin-id-fix-callback_target (state-ref state 85))
    (set! compiler-builtin-id-fix-Choice (state-ref state 86))
    (set! compiler-builtin-id-fix-clone (state-ref state 87))
    (set! compiler-builtin-id-fix-CloneShortList (state-ref state 88))
    (set! compiler-builtin-id-fix-comptime (state-ref state 89))
    (set!
      compiler-builtin-id-fix-comptime_dot_comptime_error
      (state-ref state 90))
    (set! compiler-builtin-id-fix-comptime_dot_error (state-ref state 91))
    (set!
      compiler-builtin-id-fix-comptime_slash_comptime_error
      (state-ref state 92))
    (set! compiler-builtin-id-fix-comptime_slash_error (state-ref state 93))
    (set! compiler-builtin-id-fix-comptime_error (state-ref state 94))
    (set! compiler-builtin-id-fix-cond (state-ref state 95))
    (set! compiler-builtin-id-fix-Cons (state-ref state 96))
    (set! compiler-builtin-id-fix-count (state-ref state 97))
    (set! compiler-builtin-id-fix-e (state-ref state 98))
    (set! compiler-builtin-id-fix-else (state-ref state 99))
    (set! compiler-builtin-id-fix-Expr (state-ref state 100))
    (set! compiler-builtin-id-fix-ExprBindingClause (state-ref state 101))
    (set! compiler-builtin-id-fix-ExprBindingClauseList (state-ref state 102))
    (set! compiler-builtin-id-fix-ExprClause (state-ref state 103))
    (set! compiler-builtin-id-fix-ExprClauseList (state-ref state 104))
    (set! compiler-builtin-id-fix-ExprList (state-ref state 105))
    (set! compiler-builtin-id-fix-Failed (state-ref state 106))
    (set! compiler-builtin-id-fix-field (state-ref state 107))
    (set! compiler-builtin-id-fix-flag (state-ref state 108))
    (set! compiler-builtin-id-fix-h (state-ref state 109))
    (set! compiler-builtin-id-fix-helper (state-ref state 110))
    (set! compiler-builtin-id-fix-id (state-ref state 111))
    (set! compiler-builtin-id-fix-import (state-ref state 112))
    (set! compiler-builtin-id-fix-ImportedMark (state-ref state 113))
    (set! compiler-builtin-id-fix-info (state-ref state 114))
    (set! compiler-builtin-id-fix-input (state-ref state 115))
    (set! compiler-builtin-id-fix-item (state-ref state 116))
    (set! compiler-builtin-id-fix-items (state-ref state 117))
    (set! compiler-builtin-id-fix-label (state-ref state 118))
    (set! compiler-builtin-id-fix-left (state-ref state 119))
    (set! compiler-builtin-id-fix-left_slash_same (state-ref state 120))
    (set! compiler-builtin-id-fix-m (state-ref state 121))
    (set! compiler-builtin-id-fix-macro_only_helper (state-ref state 122))
    (set! compiler-builtin-id-fix-main (state-ref state 123))
    (set! compiler-builtin-id-fix-MatchArm (state-ref state 124))
    (set! compiler-builtin-id-fix-MatchArmList (state-ref state 125))
    (set! compiler-builtin-id-fix-Maybe (state-ref state 126))
    (set! compiler-builtin-id-fix-missing (state-ref state 127))
    (set! compiler-builtin-id-fix-n (state-ref state 128))
    (set!
      compiler-builtin-id-fix-name_cache_split_alias_3940
      (state-ref state 129))
    (set!
      compiler-builtin-id-fix-name_cache_split_value_3940
      (state-ref state 130))
    (set! compiler-builtin-id-fix-Nil (state-ref state 131))
    (set! compiler-builtin-id-fix-Packet (state-ref state 132))
    (set! compiler-builtin-id-fix-Pattern (state-ref state 133))
    (set! compiler-builtin-id-fix-PatternList (state-ref state 134))
    (set! compiler-builtin-id-fix-point (state-ref state 135))
    (set! compiler-builtin-id-fix-Point (state-ref state 136))
    (set! compiler-builtin-id-fix-Ready (state-ref state 137))
    (set! compiler-builtin-id-fix-record (state-ref state 138))
    (set! compiler-builtin-id-fix-Record (state-ref state 139))
    (set! compiler-builtin-id-fix-Result (state-ref state 140))
    (set! compiler-builtin-id-fix-ResultIoString (state-ref state 141))
    (set! compiler-builtin-id-fix-right (state-ref state 142))
    (set! compiler-builtin-id-fix-right_slash_Some (state-ref state 143))
    (set! compiler-builtin-id-fix-same (state-ref state 144))
    (set! compiler-builtin-id-fix-second (state-ref state 145))
    (set! compiler-builtin-id-fix-Some (state-ref state 146))
    (set! compiler-builtin-id-fix-Status (state-ref state 147))
    (set! compiler-builtin-id-fix-stdlib (state-ref state 148))
    (set!
      compiler-builtin-id-fix-stdlib_dot_comptime_dot_comptime_error
      (state-ref state 149))
    (set!
      compiler-builtin-id-fix-stdlib_dot_comptime_dot_error
      (state-ref state 150))
    (set!
      compiler-builtin-id-fix-stdlib_dot_comptime_slash_comptime_error
      (state-ref state 151))
    (set!
      compiler-builtin-id-fix-stdlib_dot_comptime_slash_error
      (state-ref state 152))
    (set!
      compiler-builtin-id-fix-stdlib_dot_comptime_slash_ExprBindingClause
      (state-ref state 153))
    (set!
      compiler-builtin-id-fix-stdlib_dot_comptime_slash_ExprBindingClauseList
      (state-ref state 154))
    (set!
      compiler-builtin-id-fix-stdlib_dot_comptime_slash_ExprClause
      (state-ref state 155))
    (set!
      compiler-builtin-id-fix-stdlib_dot_comptime_slash_ExprClauseList
      (state-ref state 156))
    (set! compiler-builtin-id-fix-stdlib_slash_comptime (state-ref state 157))
    (set!
      compiler-builtin-id-fix-stdlib_slash_comptime_dot_comptime_error
      (state-ref state 158))
    (set!
      compiler-builtin-id-fix-stdlib_slash_comptime_dot_error
      (state-ref state 159))
    (set!
      compiler-builtin-id-fix-stdlib_slash_comptime_slash_comptime_error
      (state-ref state 160))
    (set!
      compiler-builtin-id-fix-stdlib_slash_comptime_slash_error
      (state-ref state 161))
    (set! compiler-builtin-id-fix-stdlib_slash_string (state-ref state 162))
    (set! compiler-builtin-id-fix-string (state-ref state 163))
    (set! compiler-builtin-id-fix-subject (state-ref state 164))
    (set! compiler-builtin-id-fix-t (state-ref state 165))
    (set! compiler-builtin-id-fix-T (state-ref state 166))
    (set! compiler-builtin-id-fix-tag (state-ref state 167))
    (set! compiler-builtin-id-fix-target (state-ref state 168))
    (set! compiler-builtin-id-fix-ThreadBox (state-ref state 169))
    (set! compiler-builtin-id-fix-type (state-ref state 170))
    (set! compiler-builtin-id-fix-TypeInfoArray (state-ref state 171))
    (set! compiler-builtin-id-fix-TypeInfoBuiltin (state-ref state 172))
    (set! compiler-builtin-id-fix-TypeInfoDynArray (state-ref state 173))
    (set! compiler-builtin-id-fix-TypeInfoEnum (state-ref state 174))
    (set! compiler-builtin-id-fix-TypeInfoFunction (state-ref state 175))
    (set! compiler-builtin-id-fix-TypeInfoStruct (state-ref state 176))
    (set! compiler-builtin-id-fix-TypeInfoTuple (state-ref state 177))
    (set! compiler-builtin-id-fix-U (state-ref state 178))
    (set! compiler-builtin-id-fix-unquote (state-ref state 179))
    (set! compiler-builtin-id-fix-UsedBox (state-ref state 180))
    (set! compiler-builtin-id-fix-UsedEnum (state-ref state 181))
    (set! compiler-builtin-id-fix-value (state-ref state 182))
    (set! compiler-builtin-id-fix-x (state-ref state 183))
    (set! compiler-builtin-id-fix-xs (state-ref state 184))
    (set! compiler-builtin-id-fix-y (state-ref state 185))
    (set! compiler-builtin-id-fix-module (state-ref state 186))
    (set! compiler-builtin-id-fix-Module (state-ref state 187))
    (set! compiler-builtin-id-fix-decls (state-ref state 188))
    (set! compiler-builtin-id-fix-Decls (state-ref state 189))
    (set! compiler-builtin-id-fix-expr (state-ref state 190))
    (set!
      compiler-builtin-id-fix-lt_parse_ast_decl_vec_fallback_gt
      (state-ref state 191))
    (set! compiler-builtin-id-eq (state-ref state 192))
    (set! compiler-builtin-id-string-append (state-ref state 193))
    (set! compiler-builtin-id-string-concat (state-ref state 194))
    ;; State snapshots only carry ids and the interner generation. Invalidate
    ;; the active-table guard so install-builtins reloads those ids from the
    ;; currently installed pool instead of trusting a pre-parse snapshot.
    (set! compiler-builtin-pool-data-addr -1)
    (set! compiler-builtin-pool-len -1)
    (set! compiler-builtin-parse-initialized false)))

(define (compiler-builtin-reset!) : unit
  (begin
    (set! compiler-builtin-generation -1)
    (set! compiler-builtin-pool-data-addr -1)
    (set! compiler-builtin-pool-len -1)
    (set! compiler-builtin-parse-initialized false)))

(define (compiler-builtin-resolve-name [insert-missing : bool] [name : String]) : i64
  (match (ci.intern-lookup name)
    [(InternLookupFound id) id]
    [(InternLookupMissing)
      (if insert-missing
        (ci.intern-source-slice name 0 (ci.intern-private-string-length name))
        -1)]))

(define (compiler-builtin-load! [insert-missing : bool]) : unit
  (begin
    (set!
      compiler-builtin-id-tl-alloc
      (compiler-builtin-resolve-name insert-missing "tl_alloc"))
    (set!
      compiler-builtin-id-tl-region-mark
      (compiler-builtin-resolve-name insert-missing "tl_region_mark"))
    (set!
      compiler-builtin-id-tl-region-reset
      (compiler-builtin-resolve-name insert-missing "tl_region_reset"))
    (set!
      compiler-builtin-id-tl-arena-make
      (compiler-builtin-resolve-name insert-missing "tl_arena_make"))
    (set!
      compiler-builtin-id-tl-arena-make-atomic
      (compiler-builtin-resolve-name insert-missing "tl_arena_make_atomic"))
    (set!
      compiler-builtin-id-tl-arena-current
      (compiler-builtin-resolve-name insert-missing "tl_arena_current"))
    (set!
      compiler-builtin-id-tl-arena-set
      (compiler-builtin-resolve-name insert-missing "tl_arena_set"))
    (set!
      compiler-builtin-id-tl-arena-destroy
      (compiler-builtin-resolve-name insert-missing "tl_arena_destroy"))
    (set!
      compiler-builtin-id-tl-arena-poison-enable
      (compiler-builtin-resolve-name insert-missing "tl_arena_poison_enable"))
    (set!
      compiler-builtin-id-tl-thread-entry-ptr
      (compiler-builtin-resolve-name insert-missing "tl_thread_entry_ptr"))
    (set!
      compiler-builtin-id-tl-thread-init
      (compiler-builtin-resolve-name insert-missing "tl_thread_init"))
    (set!
      compiler-builtin-id-tl-atomic-i64-load-ptr
      (compiler-builtin-resolve-name insert-missing "tl_atomic_i64_load_ptr"))
    (set!
      compiler-builtin-id-tl-atomic-i64-store-ptr
      (compiler-builtin-resolve-name insert-missing "tl_atomic_i64_store_ptr"))
    (set!
      compiler-builtin-id-tl-atomic-i64-add-ptr
      (compiler-builtin-resolve-name insert-missing "tl_atomic_i64_add_ptr"))
    (set!
      compiler-builtin-id-tl-atomic-i64-fetch-add-ptr
      (compiler-builtin-resolve-name
        insert-missing
        "tl_atomic_i64_fetch_add_ptr"))
    (set!
      compiler-builtin-id-tl-atomic-i64-cas-ptr
      (compiler-builtin-resolve-name insert-missing "tl_atomic_i64_cas_ptr"))
    (set!
      compiler-builtin-id-tl-atomic-i32-load-ptr
      (compiler-builtin-resolve-name insert-missing "tl_atomic_i32_load_ptr"))
    (set!
      compiler-builtin-id-tl-atomic-i32-store-ptr
      (compiler-builtin-resolve-name insert-missing "tl_atomic_i32_store_ptr"))
    (set!
      compiler-builtin-id-tl-atomic-i32-add-ptr
      (compiler-builtin-resolve-name insert-missing "tl_atomic_i32_add_ptr"))
    (set!
      compiler-builtin-id-tl-atomic-i32-fetch-add-ptr
      (compiler-builtin-resolve-name
        insert-missing
        "tl_atomic_i32_fetch_add_ptr"))
    (set!
      compiler-builtin-id-tl-atomic-i32-cas-ptr
      (compiler-builtin-resolve-name insert-missing "tl_atomic_i32_cas_ptr"))
    (set!
      compiler-builtin-id-tl-profile-alloc-total
      (compiler-builtin-resolve-name insert-missing "tl_profile_alloc_total"))
    (set!
      compiler-builtin-id-tl-profile-alloc-live
      (compiler-builtin-resolve-name insert-missing "tl_profile_alloc_live"))
    (set!
      compiler-builtin-id-tl-profile-alloc-peak
      (compiler-builtin-resolve-name insert-missing "tl_profile_alloc_peak"))
    (set!
      compiler-builtin-id-tl-profile-alloc-reset-peak
      (compiler-builtin-resolve-name
        insert-missing
        "tl_profile_alloc_reset_peak"))
    (set!
      compiler-builtin-id-tl-substring
      (compiler-builtin-resolve-name insert-missing "tl_substring"))
    (set!
      compiler-builtin-id-tl-str-view
      (compiler-builtin-resolve-name insert-missing "tl_str_view"))
    (set!
      compiler-builtin-id-tl-private-string-length
      (compiler-builtin-resolve-name insert-missing "__tl_string_length"))
    (set!
      compiler-builtin-id-tl-private-string-ref
      (compiler-builtin-resolve-name insert-missing "__tl_string_ref"))
    (set!
      compiler-builtin-id-tl-private-string-eq
      (compiler-builtin-resolve-name insert-missing "__tl_string_eq"))
    (set!
      compiler-builtin-id-tl-private-string-to-int
      (compiler-builtin-resolve-name insert-missing "__tl_string_to_int"))
    (set!
      compiler-builtin-id-tl-string-concat
      (compiler-builtin-resolve-name insert-missing "tl_string_concat"))
    (set!
      compiler-builtin-id-tl-string-concat3
      (compiler-builtin-resolve-name insert-missing "tl_string_concat3"))
    (set!
      compiler-builtin-id-tl-string-concat4
      (compiler-builtin-resolve-name insert-missing "tl_string_concat4"))
    (set!
      compiler-builtin-id-tl-string-concat5
      (compiler-builtin-resolve-name insert-missing "tl_string_concat5"))
    (set!
      compiler-builtin-id-tl-string-eq
      (compiler-builtin-resolve-name insert-missing "tl_string_eq"))
    (set!
      compiler-builtin-id-tl-string-to-int
      (compiler-builtin-resolve-name insert-missing "tl_string_to_int"))
    (set!
      compiler-builtin-id-tl-int-to-string
      (compiler-builtin-resolve-name insert-missing "tl_int_to_string"))
    (set!
      compiler-builtin-id-tl-hash-string
      (compiler-builtin-resolve-name insert-missing "tl_hash_string"))
    (set!
      compiler-builtin-id-tl-env-var-exists
      (compiler-builtin-resolve-name insert-missing "tl_env_var_exists"))
    (set!
      compiler-builtin-id-tl-env-var-value
      (compiler-builtin-resolve-name insert-missing "tl_env_var_value"))
    (set!
      compiler-builtin-id-env-path-separator
      (compiler-builtin-resolve-name insert-missing "path-separator"))
    (set!
      compiler-builtin-id-tl-oob-abort
      (compiler-builtin-resolve-name insert-missing "tl_oob_abort"))
    (set!
      compiler-builtin-id-tl-abort-label
      (compiler-builtin-resolve-name insert-missing ".L_tl_abort"))
    (set!
      compiler-builtin-id-tl-div-abort
      (compiler-builtin-resolve-name insert-missing "tl_div_abort"))
    (set!
      compiler-builtin-id-tl-shift-abort
      (compiler-builtin-resolve-name insert-missing "tl_shift_abort"))
    (set!
      compiler-builtin-id-tl-array-fill8
      (compiler-builtin-resolve-name insert-missing "tl_array_fill8"))
    (set!
      compiler-builtin-id-tl-array-zero
      (compiler-builtin-resolve-name insert-missing "tl_array_zero"))
    (set!
      compiler-builtin-id-tl-print-char
      (compiler-builtin-resolve-name insert-missing "tl_print_char"))
    (set!
      compiler-builtin-id-tl-print-f64
      (compiler-builtin-resolve-name insert-missing "tl_print_f64"))
    (set!
      compiler-builtin-id-string-length
      (compiler-builtin-resolve-name insert-missing "string-length"))
    (set!
      compiler-builtin-id-length
      (compiler-builtin-resolve-name insert-missing "length"))
    (set!
      compiler-builtin-id-string-eq
      (compiler-builtin-resolve-name insert-missing "string-eq"))
    (set!
      compiler-builtin-id-string-eq-question
      (compiler-builtin-resolve-name insert-missing "string=?"))
    (set!
      compiler-builtin-id-eq
      (compiler-builtin-resolve-name insert-missing "eq"))
    (set!
      compiler-builtin-id-string-append
      (compiler-builtin-resolve-name insert-missing "string-append"))
    (set!
      compiler-builtin-id-string-concat
      (compiler-builtin-resolve-name insert-missing "string-concat"))
    (set!
      compiler-builtin-id-string-to-int
      (compiler-builtin-resolve-name insert-missing "string->int"))
    (set!
      compiler-builtin-id-string-ref
      (compiler-builtin-resolve-name insert-missing "string-ref"))
    (set!
      compiler-builtin-id-char-at
      (compiler-builtin-resolve-name insert-missing "char-at"))
    (set!
      compiler-builtin-id-array-length
      (compiler-builtin-resolve-name insert-missing "array-length"))
    (set!
      compiler-builtin-id-private-array-length
      (compiler-builtin-resolve-name insert-missing "__tl_array-length"))
    (set!
      compiler-builtin-id-cpuid
      (compiler-builtin-resolve-name insert-missing "cpuid"))
    (set!
      compiler-builtin-id-xgetbv
      (compiler-builtin-resolve-name insert-missing "xgetbv"))
    (set!
      compiler-builtin-id-clone
      (compiler-builtin-resolve-name insert-missing "clone"))
    (set!
      compiler-builtin-id-arena-make
      (compiler-builtin-resolve-name insert-missing "arena-make"))
    (set!
      compiler-builtin-id-arena-make-atomic
      (compiler-builtin-resolve-name insert-missing "arena-make-atomic"))
    (set!
      compiler-builtin-id-arena-current
      (compiler-builtin-resolve-name insert-missing "arena-current"))
    (set!
      compiler-builtin-id-arena-mark
      (compiler-builtin-resolve-name insert-missing "arena-mark"))
    (set!
      compiler-builtin-id-arena-set-bang
      (compiler-builtin-resolve-name insert-missing "arena-set!"))
    (set!
      compiler-builtin-id-arena-destroy
      (compiler-builtin-resolve-name insert-missing "arena-destroy"))
    (set!
      compiler-builtin-id-arena-rewind
      (compiler-builtin-resolve-name insert-missing "arena-rewind"))
    (set!
      compiler-builtin-id-tls-current-arena
      (compiler-builtin-resolve-name insert-missing "tls-current-arena"))
    (set!
      compiler-builtin-id-tls-current-arena-set-bang
      (compiler-builtin-resolve-name insert-missing "tls-current-arena-set!"))
    (set!
      compiler-builtin-id-tl-tls-current-arena-load
      (compiler-builtin-resolve-name insert-missing "tl_tls_current_arena_load"))
    (set!
      compiler-builtin-id-tl-tls-current-arena-store
      (compiler-builtin-resolve-name
        insert-missing
        "tl_tls_current_arena_store"))
    (set!
      compiler-builtin-id-fix-empty
      (compiler-builtin-resolve-name insert-missing ""))
    (set!
      compiler-builtin-id-fix-dollar_lower_dot_precise_type_dce
      (compiler-builtin-resolve-name insert-missing "$lower.precise-type-dce"))
    (set!
      compiler-builtin-id-fix-colon
      (compiler-builtin-resolve-name insert-missing ":"))
    (set!
      compiler-builtin-id-fix-tl_unquote_set_target
      (compiler-builtin-resolve-name insert-missing "__tl_unquote_set_target"))
    (set!
      compiler-builtin-id-fix-lt_ast_decl_list_fallback_gt
      (compiler-builtin-resolve-name insert-missing "<ast-decl-list-fallback>"))
    (set!
      compiler-builtin-id-fix-acc
      (compiler-builtin-resolve-name insert-missing "acc"))
    (set!
      compiler-builtin-id-fix-alias
      (compiler-builtin-resolve-name insert-missing "alias"))
    (set!
      compiler-builtin-id-fix-arena_dot_Arena
      (compiler-builtin-resolve-name insert-missing "arena.Arena"))
    (set!
      compiler-builtin-id-fix-ArenaMark
      (compiler-builtin-resolve-name insert-missing "ArenaMark"))
    (set!
      compiler-builtin-id-fix-arm
      (compiler-builtin-resolve-name insert-missing "arm"))
    (set!
      compiler-builtin-id-fix-Box
      (compiler-builtin-resolve-name insert-missing "Box"))
    (set!
      compiler-builtin-id-fix-c
      (compiler-builtin-resolve-name insert-missing "c"))
    (set!
      compiler-builtin-id-fix-callback_target
      (compiler-builtin-resolve-name insert-missing "callback-target"))
    (set!
      compiler-builtin-id-fix-Choice
      (compiler-builtin-resolve-name insert-missing "Choice"))
    (set!
      compiler-builtin-id-fix-clone
      (compiler-builtin-resolve-name insert-missing "clone"))
    (set!
      compiler-builtin-id-fix-CloneShortList
      (compiler-builtin-resolve-name insert-missing "CloneShortList"))
    (set!
      compiler-builtin-id-fix-comptime
      (compiler-builtin-resolve-name insert-missing "comptime"))
    (set!
      compiler-builtin-id-fix-comptime_dot_comptime_error
      (compiler-builtin-resolve-name insert-missing "comptime.comptime-error"))
    (set!
      compiler-builtin-id-fix-comptime_dot_error
      (compiler-builtin-resolve-name insert-missing "comptime.error"))
    (set!
      compiler-builtin-id-fix-comptime_slash_comptime_error
      (compiler-builtin-resolve-name insert-missing "comptime/comptime-error"))
    (set!
      compiler-builtin-id-fix-comptime_slash_error
      (compiler-builtin-resolve-name insert-missing "comptime/error"))
    (set!
      compiler-builtin-id-fix-comptime_error
      (compiler-builtin-resolve-name insert-missing "comptime-error"))
    (set!
      compiler-builtin-id-fix-cond
      (compiler-builtin-resolve-name insert-missing "cond"))
    (set!
      compiler-builtin-id-fix-Cons
      (compiler-builtin-resolve-name insert-missing "Cons"))
    (set!
      compiler-builtin-id-fix-count
      (compiler-builtin-resolve-name insert-missing "count"))
    (set!
      compiler-builtin-id-fix-e
      (compiler-builtin-resolve-name insert-missing "e"))
    (set!
      compiler-builtin-id-fix-else
      (compiler-builtin-resolve-name insert-missing "else"))
    (set!
      compiler-builtin-id-fix-Expr
      (compiler-builtin-resolve-name insert-missing "Expr"))
    (set!
      compiler-builtin-id-fix-ExprBindingClause
      (compiler-builtin-resolve-name insert-missing "ExprBindingClause"))
    (set!
      compiler-builtin-id-fix-ExprBindingClauseList
      (compiler-builtin-resolve-name insert-missing "ExprBindingClauseList"))
    (set!
      compiler-builtin-id-fix-ExprClause
      (compiler-builtin-resolve-name insert-missing "ExprClause"))
    (set!
      compiler-builtin-id-fix-ExprClauseList
      (compiler-builtin-resolve-name insert-missing "ExprClauseList"))
    (set!
      compiler-builtin-id-fix-ExprList
      (compiler-builtin-resolve-name insert-missing "ExprList"))
    (set!
      compiler-builtin-id-fix-Failed
      (compiler-builtin-resolve-name insert-missing "Failed"))
    (set!
      compiler-builtin-id-fix-field
      (compiler-builtin-resolve-name insert-missing "field"))
    (set!
      compiler-builtin-id-fix-flag
      (compiler-builtin-resolve-name insert-missing "flag"))
    (set!
      compiler-builtin-id-fix-h
      (compiler-builtin-resolve-name insert-missing "h"))
    (set!
      compiler-builtin-id-fix-helper
      (compiler-builtin-resolve-name insert-missing "helper"))
    (set!
      compiler-builtin-id-fix-id
      (compiler-builtin-resolve-name insert-missing "id"))
    (set!
      compiler-builtin-id-fix-import
      (compiler-builtin-resolve-name insert-missing "import"))
    (set!
      compiler-builtin-id-fix-ImportedMark
      (compiler-builtin-resolve-name insert-missing "ImportedMark"))
    (set!
      compiler-builtin-id-fix-info
      (compiler-builtin-resolve-name insert-missing "info"))
    (set!
      compiler-builtin-id-fix-input
      (compiler-builtin-resolve-name insert-missing "input"))
    (set!
      compiler-builtin-id-fix-item
      (compiler-builtin-resolve-name insert-missing "item"))
    (set!
      compiler-builtin-id-fix-items
      (compiler-builtin-resolve-name insert-missing "items"))
    (set!
      compiler-builtin-id-fix-label
      (compiler-builtin-resolve-name insert-missing "label"))
    (set!
      compiler-builtin-id-fix-left
      (compiler-builtin-resolve-name insert-missing "left"))
    (set!
      compiler-builtin-id-fix-left_slash_same
      (compiler-builtin-resolve-name insert-missing "left/same"))
    (set!
      compiler-builtin-id-fix-m
      (compiler-builtin-resolve-name insert-missing "m"))
    (set!
      compiler-builtin-id-fix-macro_only_helper
      (compiler-builtin-resolve-name insert-missing "macro-only-helper"))
    (set!
      compiler-builtin-id-fix-main
      (compiler-builtin-resolve-name insert-missing "main"))
    (set!
      compiler-builtin-id-fix-MatchArm
      (compiler-builtin-resolve-name insert-missing "MatchArm"))
    (set!
      compiler-builtin-id-fix-MatchArmList
      (compiler-builtin-resolve-name insert-missing "MatchArmList"))
    (set!
      compiler-builtin-id-fix-Maybe
      (compiler-builtin-resolve-name insert-missing "Maybe"))
    (set!
      compiler-builtin-id-fix-missing
      (compiler-builtin-resolve-name insert-missing "missing"))
    (set!
      compiler-builtin-id-fix-n
      (compiler-builtin-resolve-name insert-missing "n"))
    (set!
      compiler-builtin-id-fix-name_cache_split_alias_3940
      (compiler-builtin-resolve-name
        insert-missing
        "name_cache_split_alias_3940"))
    (set!
      compiler-builtin-id-fix-name_cache_split_value_3940
      (compiler-builtin-resolve-name
        insert-missing
        "name_cache_split_value_3940"))
    (set!
      compiler-builtin-id-fix-Nil
      (compiler-builtin-resolve-name insert-missing "Nil"))
    (set!
      compiler-builtin-id-fix-Packet
      (compiler-builtin-resolve-name insert-missing "Packet"))
    (set!
      compiler-builtin-id-fix-Pattern
      (compiler-builtin-resolve-name insert-missing "Pattern"))
    (set!
      compiler-builtin-id-fix-PatternList
      (compiler-builtin-resolve-name insert-missing "PatternList"))
    (set!
      compiler-builtin-id-fix-point
      (compiler-builtin-resolve-name insert-missing "point"))
    (set!
      compiler-builtin-id-fix-Point
      (compiler-builtin-resolve-name insert-missing "Point"))
    (set!
      compiler-builtin-id-fix-Ready
      (compiler-builtin-resolve-name insert-missing "Ready"))
    (set!
      compiler-builtin-id-fix-record
      (compiler-builtin-resolve-name insert-missing "record"))
    (set!
      compiler-builtin-id-fix-Record
      (compiler-builtin-resolve-name insert-missing "Record"))
    (set!
      compiler-builtin-id-fix-Result
      (compiler-builtin-resolve-name insert-missing "Result"))
    (set!
      compiler-builtin-id-fix-ResultIoString
      (compiler-builtin-resolve-name insert-missing "ResultIoString"))
    (set!
      compiler-builtin-id-fix-right
      (compiler-builtin-resolve-name insert-missing "right"))
    (set!
      compiler-builtin-id-fix-right_slash_Some
      (compiler-builtin-resolve-name insert-missing "right/Some"))
    (set!
      compiler-builtin-id-fix-same
      (compiler-builtin-resolve-name insert-missing "same"))
    (set!
      compiler-builtin-id-fix-second
      (compiler-builtin-resolve-name insert-missing "second"))
    (set!
      compiler-builtin-id-fix-Some
      (compiler-builtin-resolve-name insert-missing "Some"))
    (set!
      compiler-builtin-id-fix-Status
      (compiler-builtin-resolve-name insert-missing "Status"))
    (set!
      compiler-builtin-id-fix-stdlib
      (compiler-builtin-resolve-name insert-missing "stdlib"))
    (set!
      compiler-builtin-id-fix-stdlib_dot_comptime_dot_comptime_error
      (compiler-builtin-resolve-name
        insert-missing
        "stdlib.comptime.comptime-error"))
    (set!
      compiler-builtin-id-fix-stdlib_dot_comptime_dot_error
      (compiler-builtin-resolve-name insert-missing "stdlib.comptime.error"))
    (set!
      compiler-builtin-id-fix-stdlib_dot_comptime_slash_comptime_error
      (compiler-builtin-resolve-name
        insert-missing
        "stdlib.comptime/comptime-error"))
    (set!
      compiler-builtin-id-fix-stdlib_dot_comptime_slash_error
      (compiler-builtin-resolve-name insert-missing "stdlib.comptime/error"))
    (set!
      compiler-builtin-id-fix-stdlib_dot_comptime_slash_ExprBindingClause
      (compiler-builtin-resolve-name
        insert-missing
        "stdlib.comptime/ExprBindingClause"))
    (set!
      compiler-builtin-id-fix-stdlib_dot_comptime_slash_ExprBindingClauseList
      (compiler-builtin-resolve-name
        insert-missing
        "stdlib.comptime/ExprBindingClauseList"))
    (set!
      compiler-builtin-id-fix-stdlib_dot_comptime_slash_ExprClause
      (compiler-builtin-resolve-name
        insert-missing
        "stdlib.comptime/ExprClause"))
    (set!
      compiler-builtin-id-fix-stdlib_dot_comptime_slash_ExprClauseList
      (compiler-builtin-resolve-name
        insert-missing
        "stdlib.comptime/ExprClauseList"))
    (set!
      compiler-builtin-id-fix-stdlib_slash_comptime
      (compiler-builtin-resolve-name insert-missing "stdlib/comptime"))
    (set!
      compiler-builtin-id-fix-stdlib_slash_comptime_dot_comptime_error
      (compiler-builtin-resolve-name
        insert-missing
        "stdlib/comptime.comptime-error"))
    (set!
      compiler-builtin-id-fix-stdlib_slash_comptime_dot_error
      (compiler-builtin-resolve-name insert-missing "stdlib/comptime.error"))
    (set!
      compiler-builtin-id-fix-stdlib_slash_comptime_slash_comptime_error
      (compiler-builtin-resolve-name
        insert-missing
        "stdlib/comptime/comptime-error"))
    (set!
      compiler-builtin-id-fix-stdlib_slash_comptime_slash_error
      (compiler-builtin-resolve-name insert-missing "stdlib/comptime/error"))
    (set!
      compiler-builtin-id-fix-stdlib_slash_string
      (compiler-builtin-resolve-name insert-missing "stdlib/string"))
    (set!
      compiler-builtin-id-fix-string
      (compiler-builtin-resolve-name insert-missing "string"))
    (set!
      compiler-builtin-id-fix-subject
      (compiler-builtin-resolve-name insert-missing "subject"))
    (set!
      compiler-builtin-id-fix-t
      (compiler-builtin-resolve-name insert-missing "t"))
    (set!
      compiler-builtin-id-fix-T
      (compiler-builtin-resolve-name insert-missing "T"))
    (set!
      compiler-builtin-id-fix-tag
      (compiler-builtin-resolve-name insert-missing "tag"))
    (set!
      compiler-builtin-id-fix-target
      (compiler-builtin-resolve-name insert-missing "target"))
    (set!
      compiler-builtin-id-fix-ThreadBox
      (compiler-builtin-resolve-name insert-missing "ThreadBox"))
    (set!
      compiler-builtin-id-fix-type
      (compiler-builtin-resolve-name insert-missing "type"))
    (set!
      compiler-builtin-id-fix-TypeInfoArray
      (compiler-builtin-resolve-name insert-missing "TypeInfoArray"))
    (set!
      compiler-builtin-id-fix-TypeInfoBuiltin
      (compiler-builtin-resolve-name insert-missing "TypeInfoBuiltin"))
    (set!
      compiler-builtin-id-fix-TypeInfoDynArray
      (compiler-builtin-resolve-name insert-missing "TypeInfoDynArray"))
    (set!
      compiler-builtin-id-fix-TypeInfoEnum
      (compiler-builtin-resolve-name insert-missing "TypeInfoEnum"))
    (set!
      compiler-builtin-id-fix-TypeInfoFunction
      (compiler-builtin-resolve-name insert-missing "TypeInfoFunction"))
    (set!
      compiler-builtin-id-fix-TypeInfoStruct
      (compiler-builtin-resolve-name insert-missing "TypeInfoStruct"))
    (set!
      compiler-builtin-id-fix-TypeInfoTuple
      (compiler-builtin-resolve-name insert-missing "TypeInfoTuple"))
    (set!
      compiler-builtin-id-fix-U
      (compiler-builtin-resolve-name insert-missing "U"))
    (set!
      compiler-builtin-id-fix-unquote
      (compiler-builtin-resolve-name insert-missing "unquote"))
    (set!
      compiler-builtin-id-fix-UsedBox
      (compiler-builtin-resolve-name insert-missing "UsedBox"))
    (set!
      compiler-builtin-id-fix-UsedEnum
      (compiler-builtin-resolve-name insert-missing "UsedEnum"))
    (set!
      compiler-builtin-id-fix-value
      (compiler-builtin-resolve-name insert-missing "value"))
    (set!
      compiler-builtin-id-fix-x
      (compiler-builtin-resolve-name insert-missing "x"))
    (set!
      compiler-builtin-id-fix-xs
      (compiler-builtin-resolve-name insert-missing "xs"))
    (set!
      compiler-builtin-id-fix-y
      (compiler-builtin-resolve-name insert-missing "y"))
    (set!
      compiler-builtin-id-fix-module
      (compiler-builtin-resolve-name insert-missing "module"))
    (set!
      compiler-builtin-id-fix-Module
      (compiler-builtin-resolve-name insert-missing "Module"))
    (set!
      compiler-builtin-id-fix-decls
      (compiler-builtin-resolve-name insert-missing "decls"))
    (set!
      compiler-builtin-id-fix-Decls
      (compiler-builtin-resolve-name insert-missing "Decls"))
    (set!
      compiler-builtin-id-fix-expr
      (compiler-builtin-resolve-name insert-missing "expr"))
    (set!
      compiler-builtin-id-fix-lt_parse_ast_decl_vec_fallback_gt
      (compiler-builtin-resolve-name
        insert-missing
        "<parse-ast-decl-vec-fallback>"))
    (set! compiler-builtin-generation (ci.intern-generation))
    (set! compiler-builtin-pool-data-addr (ci.intern-pool-data-addr))
    (set! compiler-builtin-pool-len (ci.intern-pool-len))
    (set! compiler-builtin-parse-initialized insert-missing)))

(define (compiler-builtin-table-current?) : bool
  (and
    (= compiler-builtin-generation (ci.intern-generation))
    (= compiler-builtin-pool-data-addr (ci.intern-pool-data-addr))))

;; Parser/bootstrap boundary: fixed compiler spellings that did not occur in
;; the source yet are inserted exactly once for the active intern table.
(define (compiler-builtin-initialize-for-parse!) : unit
  (if (and compiler-builtin-parse-initialized (compiler-builtin-table-current?))
    unit
    (compiler-builtin-load! true)))

;; Later phases may only observe the active intern table. A partial lookup is
;; repeated when parsing grows that table, but it never inserts a spelling.
(define (compiler-builtin-refresh!) : unit
  (if (and
    (compiler-builtin-table-current?)
    (or
      compiler-builtin-parse-initialized
      (= compiler-builtin-pool-len (ci.intern-pool-len))))
    unit
    (compiler-builtin-load! false)))

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
        compiler-builtin-id-tl-thread-init))))

(define (compiler-builtin-backend-runtime-atomic-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (or
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
      (compiler-builtin-backend-runtime-atomic-id? name-id)
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
      (compiler-builtin-backend-runtime-atomic-id? name-id))))

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

(define (compiler-builtin-backend-tls-current-arena-call-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (compiler-builtin-id-any2?
      name-id
      compiler-builtin-id-tl-tls-current-arena-load
      compiler-builtin-id-tl-tls-current-arena-store)))

(define (compiler-builtin-backend-tls-current-arena-load-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tl-tls-current-arena-load)))

(define (compiler-builtin-backend-tls-current-arena-store-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tl-tls-current-arena-store)))

(define (compiler-builtin-lower-bootstrap-runtime-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (compiler-builtin-id-any2?
      name-id
      compiler-builtin-id-tl-private-string-eq
      compiler-builtin-id-tl-private-string-to-int)))

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

(define (compiler-builtin-lower-tls-current-arena-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (compiler-builtin-id-any2?
      name-id
      compiler-builtin-id-tls-current-arena
      compiler-builtin-id-tls-current-arena-set-bang)))

(define (compiler-builtin-lower-tls-current-arena-read-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tls-current-arena)))

(define (compiler-builtin-lower-string-ref-call-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tl-private-string-ref)))

(define (compiler-builtin-lower-length-call-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (or
      (compiler-builtin-id-any4?
        name-id
        compiler-builtin-id-array-length
        compiler-builtin-id-length
        compiler-builtin-id-string-length
        compiler-builtin-id-private-array-length)
      (= name-id compiler-builtin-id-tl-private-string-length))))

(define (compiler-builtin-lower-array-length-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (compiler-builtin-id-any2?
      name-id
      compiler-builtin-id-array-length
      compiler-builtin-id-private-array-length)))

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
    (= name-id compiler-builtin-id-tl-private-string-length)))

(define (compiler-builtin-typecheck-public-string-length-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-string-length)))

(define (compiler-builtin-typecheck-array-length-id? [name-id : i64]) : bool
  (compiler-builtin-lower-array-length-id? name-id))

(define (compiler-builtin-typecheck-length-call-id? [name-id : i64]) : bool
  (compiler-builtin-lower-length-call-id? name-id))

(define (compiler-builtin-typecheck-string-ref-call-id? [name-id : i64]) : bool
  (compiler-builtin-lower-string-ref-call-id? name-id))

(define (compiler-builtin-typecheck-public-string-ref-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (compiler-builtin-id-any2?
      name-id
      compiler-builtin-id-string-ref
      compiler-builtin-id-char-at)))

(define (compiler-builtin-typecheck-public-char-at-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-char-at)))

(define (compiler-builtin-typecheck-clone-id? [name-id : i64]) : bool
  (compiler-builtin-lower-clone-id? name-id))

(define (compiler-builtin-typecheck-tls-current-arena-id? [name-id : i64]) : bool
  (compiler-builtin-lower-tls-current-arena-id? name-id))

(define (compiler-builtin-typecheck-tls-current-arena-read-id? [name-id : i64]) : bool
  (compiler-builtin-lower-tls-current-arena-read-id? name-id))

(define (compiler-builtin-typecheck-region-arg-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (or
      (compiler-builtin-id-any4?
        name-id
        compiler-builtin-id-tl-private-string-length
        compiler-builtin-id-length
        compiler-builtin-id-array-length
        compiler-builtin-id-tl-private-string-eq)
      (= name-id compiler-builtin-id-tl-private-string-to-int))))

(define (compiler-builtin-typecheck-string-eq-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tl-private-string-eq)))

(define (compiler-builtin-typecheck-public-string-eq-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (compiler-builtin-id-any2?
      name-id
      compiler-builtin-id-string-eq
      compiler-builtin-id-string-eq-question)))

(define (compiler-builtin-typecheck-public-string-eq-question-id?
  [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-string-eq-question)))

(define (compiler-builtin-typecheck-string-to-int-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tl-private-string-to-int)))

(define (compiler-builtin-typecheck-borrowed-string-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (or
      (compiler-builtin-typecheck-string-eq-id? name-id)
      (compiler-builtin-typecheck-string-to-int-id? name-id))))