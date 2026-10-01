;; compiler_builtin_ids.tl - reset-aware intern ids for fixed compiler builtins.
;; `compiler-builtin-id-fix-*` suffixes mechanically encode the exact source
;; spelling, including case and punctuation. Non-kebab encodings carry targeted
;; name-case allows so new ordinary bindings remain covered by the lint gate.
(import stdlib.io)
(import stdlib.string)
(import compiler_intern as ci)
(import stdlib.comptime)
(cfg test (import stdlib.test))

(define compiler-builtin-id-c-fn-check : i64
  -1)
(define compiler-builtin-id-tl-c-fn-null-abort : i64
  -1)
(define compiler-builtin-generation : i64
  -1)
(define compiler-builtin-table-id : i64
  -1)
(define compiler-builtin-pool-len : i64
  -1)
(define compiler-builtin-parse-initialized : bool
  false)
(define compiler-builtin-id-tl-alloc : i64
  -1)
(define compiler-builtin-id-tl-alloc-aligned : i64
  -1)
(define compiler-builtin-id-tl-region-mark : i64
  -1)
(define compiler-builtin-id-tl-region-reset : i64
  -1)
(define compiler-builtin-id-tl-arena-make : i64
  -1)
(define compiler-builtin-id-tl-arena-make-small : i64
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
(define compiler-builtin-id-tl-arena-debug-protect-never-reset : i64
  -1)
(define compiler-builtin-id-tl-arena-debug-assert-pool-install : i64
  -1)
(define compiler-builtin-id-tl-arena-debug-retire-protected : i64
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
(define compiler-builtin-id-atomic-i64-load : i64
  -1)
(define compiler-builtin-id-atomic-i64-store : i64
  -1)
(define compiler-builtin-id-atomic-i64-add : i64
  -1)
(define compiler-builtin-id-atomic-i64-fetch-add : i64
  -1)
(define compiler-builtin-id-atomic-i64-cas : i64
  -1)
(define compiler-builtin-id-atomic-i32-load : i64
  -1)
(define compiler-builtin-id-atomic-i32-store : i64
  -1)
(define compiler-builtin-id-atomic-i32-add : i64
  -1)
(define compiler-builtin-id-atomic-i32-fetch-add : i64
  -1)
(define compiler-builtin-id-atomic-i32-cas : i64
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
(define compiler-builtin-id-tl-stdin-eof-label : i64
  -1)
(define compiler-builtin-id-tl-flush-stdout-label : i64
  -1)
(define compiler-builtin-id-tl-array-fill8 : i64
  -1)
(define compiler-builtin-id-tl-array-zero : i64
  -1)
(define compiler-builtin-id-tl-mem-fill8 : i64
  -1)
(define compiler-builtin-id-tl-mem-copy-fwd : i64
  -1)
(define compiler-builtin-id-tl-mem-copy8-fwd : i64
  -1)
(define compiler-builtin-id-tl-tlci-call-macro-entry : i64
  -1)
(define compiler-builtin-id-tl-private-float-sqrt : i64
  -1)
(define compiler-builtin-id-tl-private-float-to-bits : i64
  -1)
(define compiler-builtin-id-tl-private-float-from-bits : i64
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
(define compiler-builtin-id-arena-module : i64
  -1)
(define compiler-builtin-id-arena-type : i64
  -1)
(define compiler-builtin-id-arena-mark-type : i64
  -1)
(define compiler-builtin-id-arena-phase-type : i64
  -1)
(define compiler-builtin-id-arena-make-base : i64
  -1)
(define compiler-builtin-id-arena-make-atomic-base : i64
  -1)
(define compiler-builtin-id-arena-phase-base : i64
  -1)
(define compiler-builtin-id-arena-rewind-safe-base : i64
  -1)
(define compiler-builtin-id-arena-destroy-safe-base : i64
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

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-dollar_lower_dot_precise_type_dce : i64
  -1)
(define compiler-builtin-id-fix-colon : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-tl_unquote_set_target : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-lt_ast_decl_list_fallback_gt : i64
  -1)
(define compiler-builtin-id-fix-acc : i64
  -1)
(define compiler-builtin-id-fix-alias : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-arena_dot_Arena : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-ArenaMark : i64
  -1)
(define compiler-builtin-id-fix-arm : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-Box : i64
  -1)
(define compiler-builtin-id-fix-c : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-callback_target : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-Choice : i64
  -1)
(define compiler-builtin-id-fix-clone : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-CloneShortList : i64
  -1)
(define compiler-builtin-id-fix-comptime : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-comptime_dot_comptime_error : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-comptime_dot_error : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-comptime_slash_comptime_error : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-comptime_slash_error : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-comptime_error : i64
  -1)
(define compiler-builtin-id-fix-cond : i64
  -1)
(define compiler-builtin-id-fix-when : i64
  -1)
(define compiler-builtin-id-fix-unless : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-Cons : i64
  -1)
(define compiler-builtin-id-fix-count : i64
  -1)
(define compiler-builtin-id-fix-e : i64
  -1)
(define compiler-builtin-id-fix-else : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-Expr : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-ExprBindingClause : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-ExprBindingClauseList : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-ExprClause : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-ExprClauseList : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-ExprList : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
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

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
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

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-left_slash_same : i64
  -1)
(define compiler-builtin-id-fix-m : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-macro_only_helper : i64
  -1)
(define compiler-builtin-id-fix-main : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-MatchArm : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-MatchArmList : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-LetBinding : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-LetBindingList : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-Maybe : i64
  -1)
(define compiler-builtin-id-fix-missing : i64
  -1)
(define compiler-builtin-id-fix-n : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-name_cache_split_alias_3940 : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-name_cache_split_value_3940 : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-Nil : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-Packet : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-Pattern : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-PatternList : i64
  -1)
(define compiler-builtin-id-fix-point : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-Point : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-Ready : i64
  -1)
(define compiler-builtin-id-fix-record : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-Record : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-Result : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-ResultIoString : i64
  -1)
(define compiler-builtin-id-fix-right : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-right_slash_Some : i64
  -1)
(define compiler-builtin-id-fix-same : i64
  -1)
(define compiler-builtin-id-fix-second : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-Some : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-Status : i64
  -1)
(define compiler-builtin-id-fix-stdlib : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-stdlib_dot_comptime : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-stdlib_dot_comptime_dot_comptime_error : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-stdlib_dot_comptime_dot_error : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-stdlib_dot_comptime_slash_comptime_error : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-stdlib_dot_comptime_slash_error : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-stdlib_dot_comptime_slash_ExprBindingClause : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-stdlib_dot_comptime_slash_ExprBindingClauseList : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-stdlib_dot_comptime_slash_ExprClause : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-stdlib_dot_comptime_slash_ExprClauseList : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-stdlib_slash_comptime : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-stdlib_slash_comptime_dot_comptime_error : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-stdlib_slash_comptime_dot_error : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-stdlib_slash_comptime_slash_comptime_error : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-stdlib_slash_comptime_slash_error : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-stdlib_slash_string : i64
  -1)
(define compiler-builtin-id-fix-string : i64
  -1)
(define compiler-builtin-id-fix-subject : i64
  -1)
(define compiler-builtin-id-fix-t : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-T : i64
  -1)
(define compiler-builtin-id-fix-tag : i64
  -1)
(define compiler-builtin-id-fix-target : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-ThreadBox : i64
  -1)
(define compiler-builtin-id-fix-type : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-TypeField : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-TypeFieldList : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-TypeInfo : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-TypeInfoList : i64
  -1)
(define compiler-builtin-id-comptime-type-info-array-variant : i64
  -1)
(define compiler-builtin-id-comptime-type-info-builtin-variant : i64
  -1)
(define compiler-builtin-id-comptime-type-info-dyn-array-variant : i64
  -1)
(define compiler-builtin-id-comptime-type-info-enum-variant : i64
  -1)
(define compiler-builtin-id-comptime-type-info-function-variant : i64
  -1)
(define compiler-builtin-id-comptime-type-info-struct-variant : i64
  -1)
(define compiler-builtin-id-comptime-type-info-tuple-variant : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-TypeParam : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-TypeParamList : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-TypeVariant : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-TypeVariantList : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-TypeVariantPayload : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-TypeVariantPayloadList : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-U : i64
  -1)
(define compiler-builtin-id-fix-unquote : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-UsedBox : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
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

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-Module : i64
  -1)
(define compiler-builtin-id-fix-decls : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-Decls : i64
  -1)
(define compiler-builtin-id-fix-expr : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-lt_parse_ast_decl_vec_fallback_gt : i64
  -1)
(define compiler-builtin-id-fix-append : i64
  -1)
(define compiler-builtin-id-fix-concat : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-stdlib_dot_string : i64
  -1)
(define compiler-builtin-id-runtime-module : i64
  -1)
(define compiler-builtin-id-runtime-int-to-string : i64
  -1)
(define compiler-builtin-id-runtime-substring : i64
  -1)
(define compiler-builtin-id-runtime-str-view : i64
  -1)
(define compiler-builtin-id-runtime-string-concat3 : i64
  -1)
(define compiler-builtin-id-runtime-string-concat4 : i64
  -1)
(define compiler-builtin-id-runtime-string-concat5 : i64
  -1)
(define compiler-builtin-id-runtime-atomic-i64-load-ptr : i64
  -1)
(define compiler-builtin-id-runtime-atomic-i64-store-ptr : i64
  -1)
(define compiler-builtin-id-runtime-atomic-i64-add-ptr : i64
  -1)
(define compiler-builtin-id-runtime-atomic-i64-fetch-add-ptr : i64
  -1)
(define compiler-builtin-id-runtime-atomic-i64-cas-ptr : i64
  -1)
(define compiler-builtin-id-runtime-atomic-i32-load-ptr : i64
  -1)
(define compiler-builtin-id-runtime-atomic-i32-store-ptr : i64
  -1)
(define compiler-builtin-id-runtime-atomic-i32-add-ptr : i64
  -1)
(define compiler-builtin-id-runtime-atomic-i32-fetch-add-ptr : i64
  -1)
(define compiler-builtin-id-runtime-atomic-i32-cas-ptr : i64
  -1)
(define compiler-builtin-id-tl-bytes-view-from-str-parts : i64
  -1)
(define compiler-builtin-id-tl-bytes-view-from-buf-parts : i64
  -1)
(define compiler-builtin-id-tl-bytes-mut-view-from-buf-parts : i64
  -1)
(define compiler-builtin-id-tl-bytes-view-from-bytes-parts : i64
  -1)
(define compiler-builtin-id-tl-bytes-mut-view-from-bytes-parts : i64
  -1)
(define compiler-builtin-id-core-macros-module : i64
  -1)
(define compiler-builtin-id-core-macros-legacy-module : i64
  -1)
(define compiler-builtin-id-fix-slots : i64
  -1)
(define compiler-builtin-id-tc-default-boundary : i64
  -1)
(define compiler-builtin-id-tc-active-region : i64
  -1)
(define compiler-builtin-id-tc-cleanup-owner : i64
  -1)
(define compiler-builtin-id-tc-ordinary-arena-owner : i64
  -1)
(define compiler-builtin-id-tc-atomic-arena-owner : i64
  -1)
(define compiler-builtin-id-tc-return-type : i64
  -1)
(define compiler-builtin-id-tc-loop-target : i64
  -1)
(define compiler-builtin-id-tc-hygiene-global-boundary : i64
  -1)
(define compiler-builtin-id-tc-unsafe-context : i64
  -1)
(define compiler-builtin-id-fix-body : i64
  -1)
(define compiler-builtin-id-comptime-expr-begin-variant : i64
  -1)
(define compiler-builtin-id-comptime-expr-bool-variant : i64
  -1)
(define compiler-builtin-id-comptime-expr-call-variant : i64
  -1)
(define compiler-builtin-id-comptime-expr-if-variant : i64
  -1)
(define compiler-builtin-id-comptime-expr-int-variant : i64
  -1)
(define compiler-builtin-id-comptime-expr-quasiquote-variant : i64
  -1)
(define compiler-builtin-id-comptime-expr-quote-variant : i64
  -1)
(define compiler-builtin-id-comptime-expr-splice-variant : i64
  -1)
(define compiler-builtin-id-comptime-expr-unquote-variant : i64
  -1)
(define compiler-builtin-id-comptime-expr-unquote-splicing-variant : i64
  -1)
(define compiler-builtin-id-comptime-expr-var-variant : i64
  -1)
(define compiler-builtin-id-fix-first : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-has_type : i64
  -1)
(define compiler-builtin-id-fix-init : i64
  -1)
(define compiler-builtin-id-fix-len : i64
  -1)
(define compiler-builtin-id-comptime-pattern-binding-variant : i64
  -1)
(define compiler-builtin-id-comptime-pattern-variant-variant : i64
  -1)
(define compiler-builtin-id-comptime-pattern-wildcard-variant : i64
  -1)
(define compiler-builtin-id-fix-payloads : i64
  -1)
(define compiler-builtin-id-comptime-type-info-opaque-variant : i64
  -1)
(define compiler-builtin-id-comptime-type-info-slice-variant : i64
  -1)
(define compiler-builtin-id-fix-name : i64
  -1)
(define compiler-builtin-id-fix-pattern : i64
  -1)
(define compiler-builtin-id-fix-ty : i64
  -1)
(define compiler-builtin-id-fix-handle : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-stdlib_dot_clone : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-synthesize_helpers : i64
  -1)

;; lint-allow: global-name-case -- fixed-ID binding encodes source spelling
(define compiler-builtin-id-fix-stdlib_dot_clone_dot_synthesize_helpers : i64
  -1)

(defstruct CompilerBuiltinIdsState
  ;; generation, table id, pool length, parse-initialized flag
  (metadata (__tl_dyn-array i64))
  (ids (__tl_dyn-array i64))
  (ctfe-ids (__tl_dyn-array i64)))

;; The builtin id tables. `(compiler-builtin-id-table fixed)` and
;; `(compiler-builtin-id-table ctfe)` each declare one table from its rows, so a
;; table's rows are read once and each expansion stays within the CTFE budget.
;;
;; The fixed table: a row `(id global slot "spelling")` ties a
;; `compiler-builtin-id-*` global (declared above) to its slot in
;; `CompilerBuiltinIdsState.ids` and to the source spelling it interns. A row
;; without a spelling is captured but never loaded, so its global stays -1.
;; Rows are in load order, which is the order their spellings enter the intern
;; table. It declares:
;; - `compiler-builtin-id-slot-count`, one past the largest slot: the length
;;   of the id array, so every row's slot is in bounds;
;; - `state-capture-fixed-ids!` and `state-install-fixed-ids!`: one load and one
;;   store per row through the id array's data pointer;
;; - `state-load-fixed-ids!`, which interns the spellings into a state.
;;
;; The CTFE catalog: a row `(ctfe slot "spelling")` ties a CTFE builtin's
;; spelling to its slot in `CompilerBuiltinIdsState.ctfe-ids`. Rows are in
;; ascending slot order, which is the order the loader interns them. A
;; `(ctfe slot "spelling" repeat)` row loads a spelling that an earlier row
;; already maps to its own slot. It declares:
;; - `compiler-builtin-ctfe-ids`, one past the largest slot long;
;; - `compiler-builtin-ctfe-slot`, a `match` from each spelling to the slot of
;;   its first row; any other spelling fails to compile;
;; - `state-load-ctfe-ids!`, which interns the spellings into a state.
;;
;; Slots are append-only; a slot without a row is retired or reserved and stays
;; -1. Loading makes one `compiler-builtin-load-id-rows!` call per 16 rows, each
;; row `slot:spelling|`; chunks keep the comptime string building short.
(defmacro (compiler-builtin-id-table [which : comptime.Expr]) : Decls
  (let
    [fixed? : bool
      (match which
        [(comptime.Expr.Var name)
          (if (string-eq name "fixed")
            true
            (if (string-eq name "ctfe")
              false
              (comptime.comptime-error
                "compiler-builtin-id-table: the table is fixed or ctfe")))]
        [_
          (comptime.comptime-error
            "compiler-builtin-id-table: the table is fixed or ctfe")])]
    [rows : comptime.ExprList
      (match (if fixed?
        `(rows
          (id compiler-builtin-id-tl-alloc 0 "tl_alloc")
          ;; Append-only slot for the compiler-private aligned allocator.
          (id compiler-builtin-id-tl-alloc-aligned 319 "tl_alloc_aligned")
          (id compiler-builtin-id-tl-region-mark 1 "tl_region_mark")
          (id compiler-builtin-id-tl-region-reset 2 "tl_region_reset")
          (id compiler-builtin-id-tl-arena-make 3 "tl_arena_make")
          (id compiler-builtin-id-tl-arena-make-small 310 "tl_arena_make_small")
          (id compiler-builtin-id-tl-arena-make-atomic 4 "tl_arena_make_atomic")
          (id compiler-builtin-id-tl-arena-current 5 "tl_arena_current")
          (id compiler-builtin-id-tl-arena-set 6 "tl_arena_set")
          (id compiler-builtin-id-tl-arena-destroy 7 "tl_arena_destroy")
          (id
            compiler-builtin-id-tl-arena-poison-enable
            8
            "tl_arena_poison_enable")
          (id
            compiler-builtin-id-tl-arena-debug-retire-protected
            320
            "tl_arena_debug_retire_protected")
          (id
            compiler-builtin-id-tl-arena-debug-protect-never-reset
            313
            "tl_arena_debug_protect_never_reset")
          (id
            compiler-builtin-id-tl-arena-debug-assert-pool-install
            314
            "tl_arena_debug_assert_pool_install")
          (id compiler-builtin-id-tl-thread-entry-ptr 9 "tl_thread_entry_ptr")
          (id compiler-builtin-id-tl-thread-init 10 "tl_thread_init")
          (id
            compiler-builtin-id-tl-atomic-i64-load-ptr
            11
            "tl_atomic_i64_load_ptr")
          (id
            compiler-builtin-id-tl-atomic-i64-store-ptr
            12
            "tl_atomic_i64_store_ptr")
          (id
            compiler-builtin-id-tl-atomic-i64-add-ptr
            13
            "tl_atomic_i64_add_ptr")
          (id
            compiler-builtin-id-tl-atomic-i64-fetch-add-ptr
            14
            "tl_atomic_i64_fetch_add_ptr")
          (id
            compiler-builtin-id-tl-atomic-i64-cas-ptr
            62
            "tl_atomic_i64_cas_ptr")
          (id
            compiler-builtin-id-tl-atomic-i32-load-ptr
            15
            "tl_atomic_i32_load_ptr")
          (id
            compiler-builtin-id-tl-atomic-i32-store-ptr
            16
            "tl_atomic_i32_store_ptr")
          (id
            compiler-builtin-id-tl-atomic-i32-add-ptr
            17
            "tl_atomic_i32_add_ptr")
          (id
            compiler-builtin-id-tl-atomic-i32-fetch-add-ptr
            18
            "tl_atomic_i32_fetch_add_ptr")
          (id
            compiler-builtin-id-tl-atomic-i32-cas-ptr
            63
            "tl_atomic_i32_cas_ptr")
          (id compiler-builtin-id-atomic-i64-load 284 "atomic-i64-load")
          (id compiler-builtin-id-atomic-i64-store 285 "atomic-i64-store!")
          (id compiler-builtin-id-atomic-i64-add 286 "atomic-i64-add!")
          (id
            compiler-builtin-id-atomic-i64-fetch-add
            287
            "atomic-i64-fetch-add!")
          (id compiler-builtin-id-atomic-i64-cas 288 "atomic-i64-cas!")
          (id compiler-builtin-id-atomic-i32-load 289 "atomic-i32-load")
          (id compiler-builtin-id-atomic-i32-store 290 "atomic-i32-store!")
          (id compiler-builtin-id-atomic-i32-add 291 "atomic-i32-add!")
          (id
            compiler-builtin-id-atomic-i32-fetch-add
            292
            "atomic-i32-fetch-add!")
          (id compiler-builtin-id-atomic-i32-cas 293 "atomic-i32-cas!")
          (id
            compiler-builtin-id-tl-profile-alloc-total
            19
            "tl_profile_alloc_total")
          (id
            compiler-builtin-id-tl-profile-alloc-live
            20
            "tl_profile_alloc_live")
          (id
            compiler-builtin-id-tl-profile-alloc-peak
            21
            "tl_profile_alloc_peak")
          (id
            compiler-builtin-id-tl-profile-alloc-reset-peak
            22
            "tl_profile_alloc_reset_peak")
          (id compiler-builtin-id-tl-substring 23 "tl_substring")
          (id compiler-builtin-id-tl-str-view 24 "tl_str_view")
          (id
            compiler-builtin-id-tl-private-string-length
            65
            "__tl_string_length")
          (id compiler-builtin-id-tl-private-string-ref 66 "__tl_string_ref")
          (id compiler-builtin-id-tl-private-string-eq 67 "__tl_string_eq")
          (id
            compiler-builtin-id-tl-private-string-to-int
            68
            "__tl_string_to_int")
          (id compiler-builtin-id-tl-string-concat 25 "tl_string_concat")
          (id compiler-builtin-id-tl-string-concat3 26 "tl_string_concat3")
          (id compiler-builtin-id-tl-string-concat4 27 "tl_string_concat4")
          (id compiler-builtin-id-tl-string-concat5 28 "tl_string_concat5")
          (id compiler-builtin-id-tl-string-eq 29 "tl_string_eq")
          (id compiler-builtin-id-tl-string-to-int 30 "tl_string_to_int")
          (id compiler-builtin-id-tl-int-to-string 31 "tl_int_to_string")
          (id compiler-builtin-id-tl-hash-string 32 "tl_hash_string")
          (id compiler-builtin-id-tl-env-var-exists 33 "tl_env_var_exists")
          (id compiler-builtin-id-tl-env-var-value 34 "tl_env_var_value")
          (id compiler-builtin-id-env-path-separator 35 "path-separator")
          (id compiler-builtin-id-tl-oob-abort 36 "tl_oob_abort")
          (id compiler-builtin-id-tl-abort-label 37 ".L_tl_abort")
          (id compiler-builtin-id-tl-div-abort 38 "tl_div_abort")
          (id compiler-builtin-id-tl-shift-abort 39 "tl_shift_abort")
          (id compiler-builtin-id-tl-stdin-eof-label 308 ".L_tl_stdin_eof")
          (id
            compiler-builtin-id-tl-flush-stdout-label
            309
            ".L_tl_flush_stdout")
          (id compiler-builtin-id-tl-array-fill8 40 "tl_array_fill8")
          (id compiler-builtin-id-tl-array-zero 41 "tl_array_zero")
          (id compiler-builtin-id-c-fn-check 321 "c-fn-check")
          (id compiler-builtin-id-tl-c-fn-null-abort 322 "tl_c_fn_null_abort")
          (id compiler-builtin-id-tl-mem-fill8 316 "tl_mem_fill8")
          (id compiler-builtin-id-tl-mem-copy-fwd 317 "tl_mem_copy_fwd")
          (id compiler-builtin-id-tl-mem-copy8-fwd 318 "tl_mem_copy8_fwd")
          (id
            compiler-builtin-id-tl-tlci-call-macro-entry
            294
            "tl_tlci_call_macro_entry")
          (id compiler-builtin-id-tl-private-float-sqrt 296 "__tl_float_sqrt")
          (id
            compiler-builtin-id-tl-private-float-to-bits
            297
            "__tl_float_to_bits")
          (id
            compiler-builtin-id-tl-private-float-from-bits
            298
            "__tl_float_from_bits")
          (id compiler-builtin-id-string-length 44 "string-length")
          (id compiler-builtin-id-length 45 "length")
          (id compiler-builtin-id-string-eq 46 "string-eq")
          (id compiler-builtin-id-string-eq-question 47 "string=?")
          (id compiler-builtin-id-eq 192 "eq")
          (id compiler-builtin-id-string-append 193 "string-append")
          (id compiler-builtin-id-string-concat 194 "string-concat")
          (id compiler-builtin-id-string-to-int 48 ">int")
          (id compiler-builtin-id-string-ref 49 "string-ref")
          (id compiler-builtin-id-char-at 50 "char-at")
          (id compiler-builtin-id-array-length 51 "array-length")
          (id compiler-builtin-id-private-array-length 64 "__tl_array-length")
          (id compiler-builtin-id-cpuid 52 "cpuid")
          (id compiler-builtin-id-xgetbv 53 "xgetbv")
          (id compiler-builtin-id-clone 54 "clone")
          (id compiler-builtin-id-arena-make 55 "arena-make")
          (id compiler-builtin-id-arena-make-atomic 56 "arena-make-atomic")
          (id compiler-builtin-id-arena-current 57 "arena-current")
          (id compiler-builtin-id-arena-mark 58 "arena-mark")
          (id compiler-builtin-id-arena-set-bang 59 "arena-set!")
          (id compiler-builtin-id-arena-destroy 60 "arena-destroy")
          (id compiler-builtin-id-arena-rewind 61 "arena-rewind")
          (id compiler-builtin-id-tls-current-arena 69 "tls-current-arena")
          (id
            compiler-builtin-id-tls-current-arena-set-bang
            70
            "tls-current-arena-set!")
          (id
            compiler-builtin-id-tl-tls-current-arena-load
            71
            "tl_tls_current_arena_load")
          (id
            compiler-builtin-id-tl-tls-current-arena-store
            72
            "tl_tls_current_arena_store")
          (id compiler-builtin-id-fix-empty 73 "")
          (id
            compiler-builtin-id-fix-dollar_lower_dot_precise_type_dce
            74
            "$lower.precise-type-dce")
          (id compiler-builtin-id-fix-colon 75 ":")
          (id
            compiler-builtin-id-fix-tl_unquote_set_target
            76
            "__tl_unquote_set_target")
          (id
            compiler-builtin-id-fix-lt_ast_decl_list_fallback_gt
            77
            "<ast-decl-list-fallback>")
          (id compiler-builtin-id-fix-acc 78 "acc")
          (id compiler-builtin-id-fix-alias 79 "alias")
          (id compiler-builtin-id-fix-arena_dot_Arena 80 "arena.Arena")
          (id compiler-builtin-id-fix-ArenaMark 81 "ArenaMark")
          (id compiler-builtin-id-fix-arm 82 "arm")
          (id compiler-builtin-id-fix-Box 83 "Box")
          (id compiler-builtin-id-fix-c 84 "c")
          (id compiler-builtin-id-fix-callback_target 85 "callback-target")
          (id compiler-builtin-id-fix-Choice 86 "Choice")
          (id compiler-builtin-id-fix-clone 87 "clone")
          (id compiler-builtin-id-fix-CloneShortList 88 "CloneShortList")
          (id compiler-builtin-id-fix-comptime 89 "comptime")
          (id
            compiler-builtin-id-fix-comptime_dot_comptime_error
            90
            "comptime.comptime-error")
          (id compiler-builtin-id-fix-comptime_dot_error 91 "comptime.error")
          (id
            compiler-builtin-id-fix-comptime_slash_comptime_error
            92
            "comptime/comptime-error")
          (id compiler-builtin-id-fix-comptime_slash_error 93 "comptime/error")
          (id compiler-builtin-id-fix-comptime_error 94 "comptime-error")
          (id compiler-builtin-id-fix-cond 95 "cond")
          (id compiler-builtin-id-fix-when 268 "when")
          (id compiler-builtin-id-fix-unless 269 "unless")
          (id compiler-builtin-id-fix-Cons 96 "Cons")
          (id compiler-builtin-id-fix-count 97 "count")
          (id compiler-builtin-id-fix-e 98 "e")
          (id compiler-builtin-id-fix-else 99 "else")
          (id compiler-builtin-id-fix-Expr 100 "Expr")
          (id compiler-builtin-id-fix-ExprBindingClause 101 "ExprBindingClause")
          (id
            compiler-builtin-id-fix-ExprBindingClauseList
            102
            "ExprBindingClauseList")
          (id compiler-builtin-id-fix-ExprClause 103 "ExprClause")
          (id compiler-builtin-id-fix-ExprClauseList 104 "ExprClauseList")
          (id compiler-builtin-id-fix-ExprList 105 "ExprList")
          (id compiler-builtin-id-fix-Failed 106 "Failed")
          (id compiler-builtin-id-fix-field 107 "field")
          (id compiler-builtin-id-fix-flag 108 "flag")
          (id compiler-builtin-id-fix-h 109 "h")
          (id compiler-builtin-id-fix-helper 110 "helper")
          (id compiler-builtin-id-fix-id 111 "id")
          (id compiler-builtin-id-fix-import 112 "import")
          (id compiler-builtin-id-fix-ImportedMark 113 "ImportedMark")
          (id compiler-builtin-id-fix-info 114 "info")
          (id compiler-builtin-id-fix-input 115 "input")
          (id compiler-builtin-id-fix-item 116 "item")
          (id compiler-builtin-id-fix-items 117 "items")
          (id compiler-builtin-id-fix-label 118 "label")
          (id compiler-builtin-id-fix-left 119 "left")
          (id compiler-builtin-id-fix-left_slash_same 120 "left/same")
          (id compiler-builtin-id-fix-m 121 "m")
          (id compiler-builtin-id-fix-macro_only_helper 122 "macro-only-helper")
          (id compiler-builtin-id-fix-main 123 "main")
          (id compiler-builtin-id-fix-MatchArm 124 "MatchArm")
          (id compiler-builtin-id-fix-MatchArmList 125 "MatchArmList")
          (id compiler-builtin-id-fix-Maybe 126 "Maybe")
          (id compiler-builtin-id-fix-missing 127 "missing")
          (id compiler-builtin-id-fix-n 128 "n")
          (id
            compiler-builtin-id-fix-name_cache_split_alias_3940
            129
            "name_cache_split_alias_3940")
          (id
            compiler-builtin-id-fix-name_cache_split_value_3940
            130
            "name_cache_split_value_3940")
          (id compiler-builtin-id-fix-Nil 131 "Nil")
          (id compiler-builtin-id-fix-Packet 132 "Packet")
          (id compiler-builtin-id-fix-Pattern 133 "Pattern")
          (id compiler-builtin-id-fix-PatternList 134 "PatternList")
          (id compiler-builtin-id-fix-point 135 "point")
          (id compiler-builtin-id-fix-Point 136 "Point")
          (id compiler-builtin-id-fix-Ready 137 "Ready")
          (id compiler-builtin-id-fix-record 138 "record")
          (id compiler-builtin-id-fix-Record 139 "Record")
          (id compiler-builtin-id-fix-Result 140 "Result")
          (id compiler-builtin-id-fix-ResultIoString 141 "ResultIoString")
          (id compiler-builtin-id-fix-right 142 "right")
          (id compiler-builtin-id-fix-right_slash_Some 143 "right/Some")
          (id compiler-builtin-id-fix-same 144 "same")
          (id compiler-builtin-id-fix-second 145 "second")
          (id compiler-builtin-id-fix-Some 146 "Some")
          (id compiler-builtin-id-fix-Status 147 "Status")
          (id compiler-builtin-id-fix-stdlib 148 "stdlib")
          (id compiler-builtin-id-fix-stdlib_dot_comptime 195 "stdlib.comptime")
          (id
            compiler-builtin-id-fix-stdlib_dot_comptime_dot_comptime_error
            149
            "stdlib.comptime.comptime-error")
          (id
            compiler-builtin-id-fix-stdlib_dot_comptime_dot_error
            150
            "stdlib.comptime.error")
          (id
            compiler-builtin-id-fix-stdlib_dot_comptime_slash_comptime_error
            151
            "stdlib.comptime/comptime-error")
          (id
            compiler-builtin-id-fix-stdlib_dot_comptime_slash_error
            152
            "stdlib.comptime/error")
          (id
            compiler-builtin-id-fix-stdlib_dot_comptime_slash_ExprBindingClause
            153
            "stdlib.comptime/ExprBindingClause")
          (id
            compiler-builtin-id-fix-stdlib_dot_comptime_slash_ExprBindingClauseList
            154
            "stdlib.comptime/ExprBindingClauseList")
          (id
            compiler-builtin-id-fix-stdlib_dot_comptime_slash_ExprClause
            155
            "stdlib.comptime/ExprClause")
          (id
            compiler-builtin-id-fix-stdlib_dot_comptime_slash_ExprClauseList
            156
            "stdlib.comptime/ExprClauseList")
          (id
            compiler-builtin-id-fix-stdlib_slash_comptime
            157
            "stdlib/comptime")
          (id
            compiler-builtin-id-fix-stdlib_slash_comptime_dot_comptime_error
            158
            "stdlib/comptime.comptime-error")
          (id
            compiler-builtin-id-fix-stdlib_slash_comptime_dot_error
            159
            "stdlib/comptime.error")
          (id
            compiler-builtin-id-fix-stdlib_slash_comptime_slash_comptime_error
            160
            "stdlib/comptime/comptime-error")
          (id
            compiler-builtin-id-fix-stdlib_slash_comptime_slash_error
            161
            "stdlib/comptime/error")
          (id compiler-builtin-id-fix-stdlib_slash_string 162 "stdlib/string")
          (id compiler-builtin-id-fix-string 163 "string")
          (id compiler-builtin-id-fix-subject 164 "subject")
          (id compiler-builtin-id-fix-t 165 "t")
          (id compiler-builtin-id-fix-T 166 "T")
          (id compiler-builtin-id-fix-tag 167 "tag")
          (id compiler-builtin-id-fix-target 168 "target")
          (id compiler-builtin-id-fix-ThreadBox 169 "ThreadBox")
          (id compiler-builtin-id-fix-type 170 "type")
          (id compiler-builtin-id-fix-TypeField 196 "TypeField")
          (id compiler-builtin-id-fix-TypeFieldList 197 "TypeFieldList")
          (id compiler-builtin-id-fix-TypeInfo 198 "TypeInfo")
          (id compiler-builtin-id-fix-TypeInfoList 199 "TypeInfoList")
          (id compiler-builtin-id-comptime-type-info-array-variant 171 "Array")
          (id
            compiler-builtin-id-comptime-type-info-builtin-variant
            172
            "Builtin")
          (id
            compiler-builtin-id-comptime-type-info-dyn-array-variant
            173
            "DynArray")
          (id compiler-builtin-id-comptime-type-info-enum-variant 174 "Enum")
          (id
            compiler-builtin-id-comptime-type-info-function-variant
            175
            "Function")
          (id
            compiler-builtin-id-comptime-type-info-struct-variant
            176
            "Struct")
          (id compiler-builtin-id-comptime-type-info-tuple-variant 177 "Tuple")
          (id compiler-builtin-id-fix-TypeParam 200 "TypeParam")
          (id compiler-builtin-id-fix-TypeParamList 201 "TypeParamList")
          (id compiler-builtin-id-fix-TypeVariant 202 "TypeVariant")
          (id compiler-builtin-id-fix-TypeVariantList 203 "TypeVariantList")
          (id
            compiler-builtin-id-fix-TypeVariantPayload
            204
            "TypeVariantPayload")
          (id
            compiler-builtin-id-fix-TypeVariantPayloadList
            205
            "TypeVariantPayloadList")
          (id compiler-builtin-id-fix-U 178 "U")
          (id compiler-builtin-id-fix-unquote 179 "unquote")
          (id compiler-builtin-id-fix-UsedBox 180 "UsedBox")
          (id compiler-builtin-id-fix-UsedEnum 181 "UsedEnum")
          (id compiler-builtin-id-fix-value 182 "value")
          (id compiler-builtin-id-fix-x 183 "x")
          (id compiler-builtin-id-fix-xs 184 "xs")
          (id compiler-builtin-id-fix-y 185 "y")
          (id compiler-builtin-id-fix-module 186 "module")
          (id compiler-builtin-id-fix-Module 187 "Module")
          (id compiler-builtin-id-fix-decls 188 "decls")
          (id compiler-builtin-id-fix-Decls 189 "Decls")
          (id compiler-builtin-id-fix-expr 190 "expr")
          (id
            compiler-builtin-id-fix-lt_parse_ast_decl_vec_fallback_gt
            191
            "<parse-ast-decl-vec-fallback>")
          (id compiler-builtin-id-fix-append 206 "append")
          (id compiler-builtin-id-fix-concat 207 "concat")
          (id compiler-builtin-id-fix-stdlib_dot_string 208 "stdlib.string")
          (id compiler-builtin-id-runtime-module 209 "stdlib.runtime")
          (id compiler-builtin-id-runtime-int-to-string 210 "int-to-string")
          (id compiler-builtin-id-runtime-substring 211 "substring")
          (id compiler-builtin-id-runtime-str-view 212 "str-view")
          (id compiler-builtin-id-runtime-string-concat3 213 "string-concat3")
          (id compiler-builtin-id-runtime-string-concat4 214 "string-concat4")
          (id compiler-builtin-id-runtime-string-concat5 215 "string-concat5")
          (id
            compiler-builtin-id-runtime-atomic-i64-load-ptr
            216
            "atomic-i64-load-ptr")
          (id
            compiler-builtin-id-runtime-atomic-i64-store-ptr
            217
            "atomic-i64-store-ptr!")
          (id
            compiler-builtin-id-runtime-atomic-i64-add-ptr
            218
            "atomic-i64-add-ptr!")
          (id
            compiler-builtin-id-runtime-atomic-i64-fetch-add-ptr
            219
            "atomic-i64-fetch-add-ptr!")
          (id
            compiler-builtin-id-runtime-atomic-i64-cas-ptr
            220
            "atomic-i64-cas-ptr!")
          (id
            compiler-builtin-id-runtime-atomic-i32-load-ptr
            221
            "atomic-i32-load-ptr")
          (id
            compiler-builtin-id-runtime-atomic-i32-store-ptr
            222
            "atomic-i32-store-ptr!")
          (id
            compiler-builtin-id-runtime-atomic-i32-add-ptr
            223
            "atomic-i32-add-ptr!")
          (id
            compiler-builtin-id-runtime-atomic-i32-fetch-add-ptr
            224
            "atomic-i32-fetch-add-ptr!")
          (id
            compiler-builtin-id-runtime-atomic-i32-cas-ptr
            225
            "atomic-i32-cas-ptr!")
          (id
            compiler-builtin-id-tl-bytes-view-from-str-parts
            226
            "tl_bytes_view_from_str_parts")
          (id
            compiler-builtin-id-tl-bytes-view-from-buf-parts
            227
            "tl_bytes_view_from_buf_parts")
          (id
            compiler-builtin-id-tl-bytes-mut-view-from-buf-parts
            228
            "tl_bytes_mut_view_from_buf_parts")
          (id
            compiler-builtin-id-tl-bytes-view-from-bytes-parts
            229
            "tl_bytes_view_from_bytes_parts")
          (id
            compiler-builtin-id-tl-bytes-mut-view-from-bytes-parts
            230
            "tl_bytes_mut_view_from_bytes_parts")
          (id compiler-builtin-id-core-macros-module 231 "stdlib.core_macros")
          (id
            compiler-builtin-id-core-macros-legacy-module
            232
            "stdlib.core-macros")
          (id compiler-builtin-id-fix-slots 233 "slots")
          (id
            compiler-builtin-id-tc-default-boundary
            234
            "__tl_default_boundary")
          (id compiler-builtin-id-tc-active-region 235 "__tl_active_region")
          (id compiler-builtin-id-tc-cleanup-owner 236 " __tl_cleanup_owner")
          (id
            compiler-builtin-id-tc-ordinary-arena-owner
            237
            " __tl_ordinary_arena_owner")
          (id
            compiler-builtin-id-tc-atomic-arena-owner
            238
            " __tl_atomic_arena_owner")
          (id compiler-builtin-id-tc-return-type 239 "__tl_return_type")
          (id compiler-builtin-id-tc-loop-target 240 "__tl_loop_target")
          (id
            compiler-builtin-id-tc-hygiene-global-boundary
            241
            "__tl_hygiene_global_boundary")
          (id compiler-builtin-id-tc-unsafe-context 242 " __tl_unsafe_context")
          (id compiler-builtin-id-fix-body 243 "body")
          (id compiler-builtin-id-comptime-expr-begin-variant 244 "Begin")
          (id compiler-builtin-id-comptime-expr-bool-variant 245 "Bool")
          (id compiler-builtin-id-comptime-expr-call-variant 246 "Call")
          (id compiler-builtin-id-comptime-expr-if-variant 247 "If")
          (id compiler-builtin-id-comptime-expr-int-variant 248 "Int")
          (id
            compiler-builtin-id-comptime-expr-quasiquote-variant
            249
            "Quasiquote")
          (id compiler-builtin-id-comptime-expr-quote-variant 250 "Quote")
          (id compiler-builtin-id-comptime-expr-splice-variant 251 "Splice")
          (id compiler-builtin-id-comptime-expr-unquote-variant 252 "Unquote")
          (id
            compiler-builtin-id-comptime-expr-unquote-splicing-variant
            253
            "UnquoteSplicing")
          (id compiler-builtin-id-comptime-expr-var-variant 254 "Var")
          (id compiler-builtin-id-fix-first 255 "first")
          (id compiler-builtin-id-fix-has_type 256 "has-type")
          (id compiler-builtin-id-fix-init 257 "init")
          (id compiler-builtin-id-fix-len 258 "len")
          (id
            compiler-builtin-id-comptime-pattern-binding-variant
            259
            "Binding")
          (id
            compiler-builtin-id-comptime-pattern-variant-variant
            260
            "Variant")
          (id
            compiler-builtin-id-comptime-pattern-wildcard-variant
            261
            "Wildcard")
          (id compiler-builtin-id-fix-payloads 262 "payloads")
          (id
            compiler-builtin-id-comptime-type-info-opaque-variant
            263
            "Opaque")
          (id compiler-builtin-id-comptime-type-info-slice-variant 315 "Slice")
          (id compiler-builtin-id-fix-name 264 "name")
          (id compiler-builtin-id-fix-pattern 265 "pattern")
          (id compiler-builtin-id-fix-ty 266 "ty")
          (id compiler-builtin-id-fix-handle 267 "handle")
          (id compiler-builtin-id-fix-stdlib_dot_clone 270 "stdlib.clone")
          (id
            compiler-builtin-id-fix-synthesize_helpers
            271
            "synthesize-helpers")
          (id
            compiler-builtin-id-fix-stdlib_dot_clone_dot_synthesize_helpers
            272
            "stdlib.clone.synthesize-helpers")
          (id compiler-builtin-id-arena-module 299 "stdlib.arena")
          (id compiler-builtin-id-arena-type 300 "stdlib.arena/Arena")
          (id compiler-builtin-id-arena-mark-type 301 "stdlib.arena/ArenaMark")
          (id
            compiler-builtin-id-arena-phase-type
            302
            "stdlib.arena/ArenaPhase")
          (id compiler-builtin-id-arena-make-base 303 "make")
          (id compiler-builtin-id-arena-make-atomic-base 304 "make-atomic")
          (id compiler-builtin-id-arena-phase-base 305 "phase")
          (id compiler-builtin-id-arena-rewind-safe-base 306 "rewind-safe!")
          (id compiler-builtin-id-arena-destroy-safe-base 307 "destroy-safe!")
          ;; Captured into their slots but never loaded, so they stay -1.
          (id compiler-builtin-id-fix-LetBinding 311)
          (id compiler-builtin-id-fix-LetBindingList 312))
        `(rows
          (ctfe 0 "size-of")
          (ctfe 1 "align-of")
          (ctfe 2 "offset-of")
          (ctfe 3 "__tl_string_eq")
          (ctfe 4 "string-eq")
          (ctfe 5 "string=?")
          (ctfe 6 "__tl_string_length")
          (ctfe 7 "string-length")
          (ctfe 8 "length")
          (ctfe 9 "__tl_string_ref")
          (ctfe 10 "string-ref")
          (ctfe 11 "char-at")
          (ctfe 12 "__tl_string_to_int")
          (ctfe 13 ">int")
          (ctfe 14 "string-append")
          (ctfe 15 "string-concat")
          (ctfe 16 "int->string")
          (ctfe 17 "comptime-error")
          (ctfe 18 "error")
          (ctfe 19 "expr-bool?")
          (ctfe 20 "expr-bool-value")
          (ctfe 21 "expr-if?")
          (ctfe 22 "expr-if-cond")
          (ctfe 23 "expr-if-then")
          (ctfe 24 "expr-if-else")
          (ctfe 25 "expr-clause-first")
          (ctfe 26 "expr-clause-second")
          (ctfe 27 "expr-bool")
          (ctfe 28 "expr-int")
          (ctfe 29 "expr-string")
          (ctfe 30 "expr-var")
          (ctfe 31 "expr-struct-get")
          (ctfe 32 "expr-tuple-ref")
          (ctfe 33 "expr-struct-set")
          (ctfe 34 "expr-splice")
          (ctfe 35 "expr-if")
          (ctfe 36 "pattern-wildcard")
          (ctfe 37 "pattern-binding")
          (ctfe 38 "pattern-variant")
          (ctfe 39 "pattern-list-empty")
          (ctfe 40 "pattern-list-cons")
          (ctfe 41 "match-arm")
          (ctfe 42 "match-arm-list-empty")
          (ctfe 43 "match-arm-list-cons")
          (ctfe 44 "expr-match")
          (ctfe 45 "expr-type")
          (ctfe 46 "type-info")
          (ctfe 47 "module-name")
          (ctfe 48 "module-export-macro?")
          (ctfe 49 "module-hook")
          (ctfe 51 "expr-list-length")
          (ctfe 54 "expr-list-nth")
          (ctfe 56 "expr-clause-list-length")
          (ctfe 59 "expr-clause-list-nth")
          (ctfe 60 "expr-clause-list->expr-list")
          (ctfe 61 "expr-binding-clause-name")
          (ctfe 62 "expr-binding-clause-has-type?")
          (ctfe 63 "expr-binding-clause-type")
          (ctfe 64 "expr-binding-clause-init")
          (ctfe 66 "expr-binding-clause-list-length")
          (ctfe 69 "expr-binding-clause-list-nth")
          (ctfe 70 "expr-binding-clause-list->expr-list")
          (ctfe 71 "type-kind")
          (ctfe 72 "type-key")
          (ctfe 73 "type-nominal-module")
          (ctfe 74 "type-nominal-name")
          (ctfe 75 "struct-field-count")
          (ctfe 76 "struct-field-name")
          (ctfe 77 "struct-field-type")
          (ctfe 78 "enum-variant-count")
          (ctfe 79 "enum-variant-name")
          (ctfe 80 "enum-variant-payload-count")
          (ctfe 81 "enum-variant-payload-type")
          (ctfe 82 "array-element-type")
          (ctfe 83 "array-length")
          (ctfe 84 "array-dynamic?")
          (ctfe 85 "tuple-element-count")
          (ctfe 86 "tuple-element-type")
          (ctfe 87 "function-param-count")
          (ctfe 88 "function-param-type")
          (ctfe 89 "function-return-type")
          (ctfe 90 "pattern-list-bindings")
          (ctfe 91 "expr-string?")
          (ctfe 92 "expr-string-value")
          (ctfe 93 "string-slice")
          (ctfe 94 "expr-mut-borrow")
          (ctfe 95 "expr-call")
          (ctfe 96 "expr-list-empty")
          (ctfe 97 "expr-list-cons")
          (ctfe 98 "expr-mut-call0")
          (ctfe 99 "expr-mut-call1")
          (ctfe 100 "expr-mut-call2")
          (ctfe 101 "expr-list-fold-if")
          (ctfe 102 "expr-clause-list-fold-if")
          (ctfe 103 "append")
          (ctfe 104 "concat")
          (ctfe 105 ">int" repeat)
          (ctfe 106 "__typelisp internal resolved struct type")
          (ctfe 107 "__typelisp internal resolved enum type")
          (ctfe 108 "None")
          (ctfe 109 "Array")
          (ctfe 110 "&")
          (ctfe 111 "&mut")
          (ctfe 112 "in")
          (ctfe 113 "while")
          (ctfe 114 "make-array")
          (ctfe 115 "array-ref")
          (ctfe 116 "array-push!")
          (ctfe 117 "string-ref" repeat)
          (ctfe 118 "init")
          (ctfe 119 "ptr-null")
          (ctfe 120 ":")
          (ctfe 121 "if")
          (ctfe 122 "begin")
          (ctfe 123 "unsafe")
          (ctfe 124 "tuple")
          (ctfe 125 "array")
          (ctfe 126 "quote")
          (ctfe 127 "quasiquote")
          (ctfe 128 "unquote")
          (ctfe 129 "unquote-splicing")
          (ctfe 130 "return")
          (ctfe 131 "try")
          (ctfe 132 "box")
          (ctfe 133 "box-get")
          (ctfe 134 "box-take")
          (ctfe 135 "type")
          (ctfe 136 "syscall")
          (ctfe 137 "+")
          (ctfe 138 "-")
          (ctfe 139 "*")
          (ctfe 140 "/")
          (ctfe 141 "%")
          (ctfe 142 "=")
          (ctfe 143 "!=")
          (ctfe 144 "<")
          (ctfe 145 "<=")
          (ctfe 146 ">")
          (ctfe 147 ">=")
          (ctfe 148 "and")
          (ctfe 149 "or")
          (ctfe 150 "bit-and")
          (ctfe 151 "bit-or")
          (ctfe 152 "bit-xor")
          (ctfe 153 "shl")
          (ctfe 154 "shr")
          (ctfe 155 "not")
          (ctfe 156 "bit-not")
          (ctfe 157 "set!")
          (ctfe 158 "String")
          (ctfe 159 "i64")
          (ctfe 160 "i32")
          (ctfe 161 "i16")
          (ctfe 162 "i8")
          (ctfe 163 "u64")
          (ctfe 164 "u32")
          (ctfe 165 "u16")
          (ctfe 166 "u8")
          (ctfe 167 "f64")
          (ctfe 168 "f32")
          (ctfe 169 "bool")
          (ctfe 170 "char")
          (ctfe 171 "str")
          (ctfe 172 "bytes")
          (ctfe 173 "unit")
          (ctfe 174 "never")
          (ctfe 175 "Tuple")
          (ctfe 176 "->")
          (ctfe 177 "Ptr")
          (ctfe 178 "MutPtr")
          (ctfe 179 ":consume")
          (ctfe 180 "_")
          (ctfe 181 "let")
          (ctfe 182 "match")
          (ctfe 183 "struct-get")
          (ctfe 184 "array-set!")
          (ctfe 186 "cast")
          (ctfe 187 "ann")
          (ctfe 188 "tuple-ref")
          (ctfe 189 "ptr-null?")
          (ctfe 190 "ptr-addr-of")
          (ctfe 191 "ptr-read")
          (ctfe 192 "ptr-write!")
          (ctfe 193 "ptr-offset")
          (ctfe 194 "ptr-cast")
          (ctfe 195 "ptr->int")
          (ctfe 196 "int->ptr")
          (ctfe 197 "string-data")
          (ctfe 198 "string-from-bytes")
          (ctfe 199 "array-data")
          (ctfe 200 "program-argc")
          (ctfe 201 "program-argv")
          (ctfe 202 "program-envp")
          (ctfe 203 "cpuid-eax")
          (ctfe 204 "cpuid-ebx")
          (ctfe 205 "cpuid-ecx")
          (ctfe 206 "cpuid-edx")
          (ctfe 207 "xgetbv")
          (ctfe 208 "true")
          (ctfe 209 "false")
          (ctfe 210 "type-cleanup-owning?")
          (ctfe 211 "type-cleanup-function")
          (ctfe 212 "expr-binary-data")
          (ctfe 213 "__typelisp internal binary data")
          (ctfe 214 "box-element-type")
          (ctfe 215 "expr-list-type-nth")
          (ctfe 216 "module-value?")
          (ctfe 217 "module-value-type")
          (ctfe 218 "reference-element-type")
          (ctfe 219 "all")
          (ctfe 220 "any")
          (ctfe 221 ":kind")
          (ctfe 222 "...")
          (ctfe 223 "string")
          (ctfe 224 "dyn-array")
          (ctfe 225 "function")
          (ctfe 226 "struct")
          (ctfe 227 "enum")
          (ctfe 228 "ptr")
          (ctfe 229 "mut-ptr")
          (ctfe 230 "ref")
          (ctfe 231 "mut-ref")
          (ctfe 232 "region")
          (ctfe 233 "type-var")
          (ctfe 234 ":cleanup")
          (ctfe 235 ":owned")
          (ctfe 236 ":lifetimes")
          (ctfe 237 ":repr")
          (ctfe 238 ":packed")
          (ctfe 239 "packed")
          (ctfe 240 "scalar")
          (ctfe 241 "avx2")
          (ctfe 242 "avx512")
          (ctfe 243 "cfg")
          (ctfe 244 "uniform")
          (ctfe 245 "varying")
          (ctfe 246 "none")
          (ctfe 247 "lanes")
          (ctfe 248 "args")
          (ctfe 249 "result")
          (ctfe 250 "index-param")
          (ctfe 251 "specialization")
          (ctfe 252 ":export-symbol")
          (ctfe 253 ":spmd-callable")
          (ctfe 254 "c-varargs")
          (ctfe 255 ":abi")
          (ctfe 256 ":symbol")
          (ctfe 257 ":link-lib")
          (ctfe 258 ":link-search")
          (ctfe 259 ":link-arg")
          (ctfe 260 "as")
          (ctfe 261 ":as")
          (ctfe 262 "sum")
          (ctfe 263 "min")
          (ctfe 264 "max")
          (ctfe 265 "defgeneric")
          (ctfe 266 "generic")
          (ctfe 267 "deftrait")
          (ctfe 268 "trait")
          (ctfe 269 "interface")
          (ctfe 270 "impl")
          (ctfe 271 "where")
          (ctfe 272 "pattern-binding-typed")
          (ctfe 273 "expr-resource-scope")
          (ctfe 274 "expr-let-scope")
          (ctfe 275 "expr-set-var")
          (ctfe 276 "expr-begin-unit")
          (ctfe 277 "expr-not")
          (ctfe 278 "expr-while")
          (ctfe 279 "syntax-name-fresh")
          (ctfe 280 "__tl_dyn-array")
          (ctfe 281 "slice")
          (ctfe 282 "expr-borrow")
          (ctfe 283 "expr-array-ref")
          (ctfe 284 "expr-replace")
          (ctfe 285 "module-value-expr")
          (ctfe 286 "function-shared-borrow-returns-string?")
          (ctfe 287 "expr-shared-call1")
          (ctfe 288 "expr-shared-let-scope")
          (ctfe 289 "type-expr")
          (ctfe 290 "expr-lambda1")
          (ctfe 291 ":ignore")
          (ctfe 292 ":slow")
          (ctfe 293 ":must-use")
          (ctfe 294 "c-function")
          (ctfe 295 "CFunc")
          (ctfe 296 "nullable")
          (ctfe 297 "non-null")
          (ctfe 298 "unsafe-nullable")
          (ctfe 299 "unsafe-non-null")
          (ctfe 300 ":invalidate")
          (ctfe 301 "invalidate")
        (ctfe 302 ":align")
        (ctfe 303 "type-declared-align")
        (ctfe 304 "struct-field-declared-align")))
        [(comptime.Expr.Call _ items) items]
        [_
          (comptime.comptime-error
            "compiler-builtin-id-table: a table is (rows row...)")])]
    [limit : i64 0]
    [capture : comptime.ExprList (comptime.expr-list-empty)]
    [install : comptime.ExprList (comptime.expr-list-empty)]
    [loads : comptime.ExprList (comptime.expr-list-empty)]
    [arms : comptime.ExprList
      (comptime.expr-list-cons
        `(_
          (comptime.comptime-error
            (comptime.string-append
              "compiler-builtin-ctfe-slot: not a CTFE builtin spelling: "
              (comptime.expr-string-value spelling))))
        (comptime.expr-list-empty))]
    [ids : comptime.Expr
      (if fixed?
        `(&mut state.ids)
        `(&mut state.ctfe-ids))]
    [chunk : String ""]
    [count : i64 0]
    [index : i64 (- (comptime.expr-list-length rows) 1)]
    (begin
      ;; Walk back to front: prepending keeps every list in row order.
      (while (>= index 0)
        (begin
          (match (comptime.expr-list-nth rows index)
            [(comptime.Expr.Call _ fields)
              (let
                [field-count : i64 (comptime.expr-list-length fields)]
                [slot : i64 -1]
                [spelling : String ""]
                [spelled? : bool false]
                [field : i64 0]
                (begin
                  ;; A row's slot is its first integer field and its spelling,
                  ;; if any, its string field.
                  (while (< field field-count)
                    (begin
                      (match (comptime.expr-list-nth fields field)
                        [(comptime.Expr.Int value)
                          (if (< slot 0)
                            (set! slot value)
                            unit)]
                        [_
                          (if (comptime.expr-string?
                            (comptime.expr-list-nth fields field))
                            (begin
                              (set!
                                spelling
                                (comptime.expr-string-value
                                  (comptime.expr-list-nth fields field)))
                              (set! spelled? true))
                            unit)])
                      (set! field (+ field 1))))
                  (if (< slot 0)
                    (comptime.comptime-error
                      "compiler-builtin-id-table: a row's slot is an integer")
                    unit)
                  (if (>= slot limit)
                    (set! limit (+ slot 1))
                    unit)
                  (if fixed?
                    (let
                      [global : comptime.Expr (comptime.expr-list-nth fields 0)]
                      [at : comptime.Expr
                        `(ptr-offset
                          compiler-builtin-ids-data
                          ,(comptime.expr-int slot))]
                      (begin
                        (set!
                          capture
                          (comptime.expr-list-cons
                            `(unsafe
                              (ptr-write! ,at ,global))
                            capture))
                        (if spelled?
                          (set!
                            install
                            (comptime.expr-list-cons
                              `(set!
                                ,global
                                (unsafe
                                  (ptr-read ,at)))
                              install))
                          unit)))
                    (if (= field-count 2)
                      (set!
                        arms
                        (comptime.expr-list-cons
                          (comptime.expr-call
                            (comptime.expr-string spelling)
                            (comptime.expr-list-cons
                              (comptime.expr-int slot)
                              (comptime.expr-list-empty)))
                          arms))
                      unit))
                  (if spelled?
                    (begin
                      (set!
                        chunk
                        (comptime.string-append
                          (comptime.string-append
                            (comptime.string-append (int->string slot) ":")
                            (comptime.string-append spelling "|"))
                          chunk))
                      (set! count (+ count 1)))
                    unit)
                  (if (= count 16)
                    (begin
                      (set!
                        loads
                        (comptime.expr-list-cons
                          `(compiler-builtin-load-id-rows!
                            ,ids
                            insert-missing
                            ,(comptime.expr-string chunk))
                          loads))
                      (set! chunk "")
                      (set! count 0))
                    unit)))]
            [_
              (comptime.comptime-error
                "compiler-builtin-id-table: a row is a call")])
          (set! index (- index 1))))
      (if (> count 0)
        (set!
          loads
          (comptime.expr-list-cons
            `(compiler-builtin-load-id-rows!
              ,ids
              insert-missing
              ,(comptime.expr-string chunk))
            loads))
        unit)
      (if fixed?
        `(begin
          (define compiler-builtin-id-slot-count : i64
            ,(comptime.expr-int limit))
          (define (state-capture-fixed-ids!
            [state : (&mut state CompilerBuiltinIdsState)]) : unit
            (let
              [compiler-builtin-ids-data : (MutPtr i64)
                (unsafe
                  (__tl_array-data (__tl-project-field state ids)))]
              (begin
                ,@capture)))
          (define (state-install-fixed-ids!
            [state : (& state CompilerBuiltinIdsState)]) : unit
            (let
              [compiler-builtin-ids-data : (MutPtr i64)
                (unsafe
                  (__tl_array-data (__tl-project-field state ids)))]
              (begin
                ,@install)))
          (define (state-load-fixed-ids!
            [state : (&mut state CompilerBuiltinIdsState)]
            [insert-missing : bool]) : unit
            (begin
              ,@loads)))
        `(begin
          (define compiler-builtin-ctfe-ids : (__tl_dyn-array i64)
            (__tl_make-array i64 ,(comptime.expr-int limit)))
          (defmacro (compiler-builtin-ctfe-slot [spelling : comptime.Expr]) : i64
            (comptime.expr-int
              ,(comptime.expr-call
                (comptime.expr-var "match")
                (comptime.expr-list-cons
                  `(comptime.expr-string-value spelling)
                  arms))))
          (define (state-load-ctfe-ids!
            [state : (&mut state CompilerBuiltinIdsState)]
            [insert-missing : bool]) : unit
            (begin
              ,@loads)))))))

(compiler-builtin-id-table fixed)

(compiler-builtin-id-table ctfe)

(define (state-new) : CompilerBuiltinIdsState
  (let
    [metadata : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    [ids : (__tl_dyn-array i64)
      (__tl_make-array i64 compiler-builtin-id-slot-count)]
    [ctfe-ids : (__tl_dyn-array i64)
      (__tl_make-array i64 (array-length compiler-builtin-ctfe-ids))]
    [i : i64 0]
    (begin
      (set! (array-ref metadata 0) -1)
      (set! (array-ref metadata 1) -1)
      (set! (array-ref metadata 2) -1)
      (set! (array-ref metadata 3) 0)
      (while (< i (array-length ids))
        (begin
          (set! (array-ref ids i) -1)
          (set! i (+ i 1))))
      (set! i 0)
      (while (< i (array-length ctfe-ids))
        (begin
          (set! (array-ref ctfe-ids i) -1)
          (set! i (+ i 1))))
      (CompilerBuiltinIdsState metadata ids ctfe-ids))))

(define (state-generation [state : (& state CompilerBuiltinIdsState)]) : i64
  (array-ref state.metadata 0))

(define (state-set-generation!
  [state : (&mut state CompilerBuiltinIdsState)]
  [generation : i64]) : unit
  (set! (array-ref state.metadata 0) generation))

(define (state-table-id [state : (& state CompilerBuiltinIdsState)]) : i64
  (array-ref state.metadata 1))

(define (state-pool-len [state : (& state CompilerBuiltinIdsState)]) : i64
  (array-ref state.metadata 2))

(define (state-parse-initialized? [state : (& state CompilerBuiltinIdsState)]) : bool
  (= (array-ref state.metadata 3) 1))

(define (state-set-metadata!
  [state : (&mut state CompilerBuiltinIdsState)]
  [table-id : i64]
  [pool-len : i64]
  [parse-initialized : bool]) : unit
  (begin
    (set! (array-ref state.metadata 1) table-id)
    (set! (array-ref state.metadata 2) pool-len)
    (set!
      (array-ref state.metadata 3)
      (if parse-initialized
        1
        0))))

(define (state-ref [state : (& state CompilerBuiltinIdsState)] [index : i64]) : i64
  (array-ref state.ids index))

;; State-owned CTFE builtin lookup: reads the state's own snapshot instead of
;; the compatibility-global CTFE id array, so an uninstalled state's table can
;; be queried without installing it.
(define (state-ctfe-ref
  [state : (& state CompilerBuiltinIdsState)]
  [index : i64]) : i64
  (array-ref state.ctfe-ids index))

;; State-owned table validation: does this state's builtin table belong to the
;; given intern generation and table id? Mirrors
;; `compiler-builtin-table-current?` for a state that may not be installed in
;; the compatibility globals; the caller passes its owning intern identity.
(define (state-table-current-with?
  [state : (& state CompilerBuiltinIdsState)]
  [generation : i64]
  [table-id : i64]) : bool
  (and
    (= (state-generation state) generation)
    (= (state-table-id state) table-id)))

(define (state-set!
  [state : (&mut state CompilerBuiltinIdsState)]
  [index : i64]
  [value : i64]) : unit
  (set! (array-ref state.ids index) value))

(define (compiler-builtin-ctfe-ref [index : i64]) : i64
  (array-ref compiler-builtin-ctfe-ids index))

(define (compiler-builtin-ctfe-set! [index : i64] [value : i64]) : unit
  (set! (array-ref compiler-builtin-ctfe-ids index) value))

(define (state-capture-ctfe-ids! [state : (&mut state CompilerBuiltinIdsState)]) : unit
  (let
    [i : i64 0]
    (while (< i (array-length state.ctfe-ids))
      (begin
        (set! (array-ref state.ctfe-ids i) (compiler-builtin-ctfe-ref i))
        (set! i (+ i 1))))))

(define (state-install-ctfe-ids! [state : (& state CompilerBuiltinIdsState)]) : unit
  (let
    [i : i64 0]
    (while (< i (array-length state.ctfe-ids))
      (begin
        (compiler-builtin-ctfe-set! i (array-ref state.ctfe-ids i))
        (set! i (+ i 1))))))

;; State-owned reset: the state's own metadata always clears so its next parse
;; re-derives the table. The compatibility-global metadata is invalidated only
;; when this state's table is the installed one -- resetting an uninstalled
;; state must not disturb whichever table the serial/legacy paths (or another
;; job state) currently have installed.
(define (state-reset! [state : (&mut state CompilerBuiltinIdsState)]) : unit
  (let
    [installed? : bool
      (and
        (>= (state-table-id state) 0)
        (= (state-table-id state) compiler-builtin-table-id))]
    (begin
      (state-set-generation! state -1)
      (state-set-metadata! state -1 -1 false)
      (if installed?
        (compiler-builtin-reset!)
        unit))))

(define (state-capture-from-globals!
  [state : (&mut state CompilerBuiltinIdsState)]) : unit
  (begin
    (state-set-generation! state compiler-builtin-generation)
    (state-set-metadata!
      state
      compiler-builtin-table-id
      compiler-builtin-pool-len
      compiler-builtin-parse-initialized)
    (state-capture-fixed-ids! state)
    (state-capture-ctfe-ids! state)))

(define (state-capture) : CompilerBuiltinIdsState
  (let
    [state : CompilerBuiltinIdsState (state-new)]
    (begin
      (state-capture-from-globals! (&mut state))
      state)))

(define (state-install! [state : (& state CompilerBuiltinIdsState)]) : unit
  (begin
    (state-install-ctfe-ids! state)
    (set! compiler-builtin-generation (state-generation state))
    (state-install-fixed-ids! state)
    (set! compiler-builtin-table-id (state-table-id state))
    (set! compiler-builtin-pool-len (state-pool-len state))
    (set! compiler-builtin-parse-initialized (state-parse-initialized? state))))

(define (compiler-builtin-reset!) : unit
  (begin
    (set! compiler-builtin-generation -1)
    (set! compiler-builtin-table-id -1)
    (set! compiler-builtin-pool-len -1)
    (set! compiler-builtin-parse-initialized false)))

(define (compiler-builtin-resolve-name [insert-missing : bool] [name : String]) : i64
  (if insert-missing
    (ci.intern-source-slice name 0 (ci.intern-private-string-length name))
    (io.panic "compiler builtin IDs must be installed with their intern table")))

(defmacro (compiler-builtin-ctfe [spelling : comptime.Expr]) : i64
  `(compiler-builtin-ctfe-ref (compiler-builtin-ctfe-slot ,spelling)))

(define (compiler-builtin-load-id-rows!
  [ids : (&mut ids (__tl_dyn-array i64))]
  [insert-missing : bool]
  [rows : String]) : unit
  (let
    [slot : i64 0]
    [start : i64 -1]
    [index : i64 0]
    ;; `start` is -1 while reading a row's slot digits.
    (while (< index (string.string-length rows))
      (let
        [c : char (string.string-ref rows index)]
        (begin
          (cond
            [(< start 0)
              (if (= c ':')
                (set! start (+ index 1))
                (set! slot (+ (* slot 10) (- (cast c : i64) 48))))]
            [(= c '|')
              (begin
                (set!
                  (array-ref ids slot)
                  (if insert-missing
                    (ci.intern-source-slice rows start (- index start))
                    (io.panic
                      "compiler builtin IDs must be installed with their intern table")))
                (set! slot 0)
                (set! start -1))]
            [else unit])
          (set! index (+ index 1)))))))

;; Interns the CTFE spellings in slot order, then the fixed ids' in table order,
;; into a fresh state, and installs it. Slots without a spelling stay -1.
(define (compiler-builtin-load! [insert-missing : bool]) : unit
  (let
    [state : CompilerBuiltinIdsState (state-new)]
    (begin
      (state-load-ctfe-ids! (&mut state) insert-missing)
      (state-load-fixed-ids! (&mut state) insert-missing)
      (state-install-ctfe-ids! (& state))
      (state-install-fixed-ids! (& state))
      (set! compiler-builtin-generation (ci.intern-generation))
      (set! compiler-builtin-table-id (ci.intern-active-table-id))
      (set! compiler-builtin-pool-len (ci.intern-pool-len))
      (set! compiler-builtin-parse-initialized insert-missing))))

(define (compiler-builtin-table-current?) : bool
  (and
    (= compiler-builtin-generation (ci.intern-generation))
    (= compiler-builtin-table-id (ci.intern-active-table-id))))

;; Parser/bootstrap boundary: fixed compiler spellings that did not occur in
;; the source yet are inserted exactly once for the active intern table.
(define (compiler-builtin-initialize-for-parse!) : unit
  (if (and compiler-builtin-parse-initialized (compiler-builtin-table-current?))
    unit
    (compiler-builtin-load! true)))

;; Later phases may only observe IDs installed for the active intern table.
;; Switching compiler state must install the matching builtin state alongside
;; the intern state; recovering IDs from their spellings hides that violation.
(define (compiler-builtin-refresh!) : unit
  (if (compiler-builtin-table-current?)
    unit
    (io.panic "compiler builtin IDs do not match the active intern table")))

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

(cfg
  test
  (define (compiler-builtin-comptime-structural-fields-current-ok?) : bool
    (let
      [generated-items : i64 (ci.intern-generated-canonical-name "items")]
      (and
        (= (ci.intern-source-slice "items" 0 5) compiler-builtin-id-fix-items)
        (not (= generated-items compiler-builtin-id-fix-items))))))

(cfg
  test
  (define (compiler-builtin-comptime-structural-fields-reset-ok?) : bool
    (begin
      (ci.intern-reset!)
      (compiler-builtin-reset!)
      (compiler-builtin-initialize-for-parse!)
      (unless
        (compiler-builtin-comptime-structural-fields-current-ok?)
        (return false))
      (ci.intern-reset!)
      (compiler-builtin-reset!)
      (compiler-builtin-initialize-for-parse!)
      (compiler-builtin-comptime-structural-fields-current-ok?))))

(cfg
  test
  (test
    compiler-builtin-comptime-structural-fields
    (if (compiler-builtin-comptime-structural-fields-reset-ok?)
      unit
      (io.panic "compiler builtin comptime structural field IDs failed"))))

(cfg
  test
  (define (compiler-builtin-comptime-private-cons-slots-empty?) : bool
    (begin
      (compiler-builtin-initialize-for-parse!)
      (and
        (= (compiler-builtin-ctfe-ref 50) -1)
        (= (compiler-builtin-ctfe-ref 52) -1)
        (= (compiler-builtin-ctfe-ref 53) -1)
        (= (compiler-builtin-ctfe-ref 55) -1)
        (= (compiler-builtin-ctfe-ref 57) -1)
        (= (compiler-builtin-ctfe-ref 58) -1)
        (= (compiler-builtin-ctfe-ref 65) -1)
        (= (compiler-builtin-ctfe-ref 67) -1)
        (= (compiler-builtin-ctfe-ref 68) -1)))))

(cfg
  test
  (test
    compiler-builtin-comptime-private-cons-slots
    (if (compiler-builtin-comptime-private-cons-slots-empty?)
      unit
      (io.panic "private comptime cons helpers leaked into the builtin catalog"))))

(cfg
  test
  (define (compiler-builtin-comptime-type-info-slice-id-current-ok?) : bool
    (begin
      (compiler-builtin-refresh!)
      (=
        compiler-builtin-id-comptime-type-info-slice-variant
        (ci.intern-source-slice "Slice" 0 5)))))

(cfg
  test
  (define (compiler-builtin-comptime-type-info-slice-id-reset-ok?) : bool
    (begin
      (ci.intern-reset!)
      (compiler-builtin-reset!)
      (compiler-builtin-initialize-for-parse!)
      (unless
        (compiler-builtin-comptime-type-info-slice-id-current-ok?)
        (return false))
      (let
        [snapshot : CompilerBuiltinIdsState (state-capture)]
        (begin
          (set! compiler-builtin-id-comptime-type-info-slice-variant -1)
          (state-install! snapshot)
          (and
            (=
              compiler-builtin-id-comptime-type-info-slice-variant
              (ci.intern-source-slice "Slice" 0 5))
            (=
              (state-ref snapshot 315)
              compiler-builtin-id-comptime-type-info-slice-variant)))))))

(cfg
  test
  (test
    compiler-builtin-comptime-type-info-slice-id
    (if (compiler-builtin-comptime-type-info-slice-id-reset-ok?)
      unit
      (io.panic "compiler builtin TypeInfo Slice ID lifecycle failed"))))

(cfg
  test
  (define (compiler-builtin-parser-syntax-ids-current-ok?) : bool
    (and
      (= (compiler-builtin-ctfe "all") (ci.intern-source-slice "all" 0 3))
      (= (compiler-builtin-ctfe "any") (ci.intern-source-slice "any" 0 3))
      (= (compiler-builtin-ctfe ":kind") (ci.intern-source-slice ":kind" 0 5))
      (= (compiler-builtin-ctfe "...") (ci.intern-source-slice "..." 0 3))
      (= (compiler-builtin-ctfe "string") (ci.intern-source-slice "string" 0 6))
      (=
        (compiler-builtin-ctfe "dyn-array")
        (ci.intern-source-slice "dyn-array" 0 9))
      (=
        (compiler-builtin-ctfe "function")
        (ci.intern-source-slice "function" 0 8))
      (= (compiler-builtin-ctfe "struct") (ci.intern-source-slice "struct" 0 6))
      (= (compiler-builtin-ctfe "enum") (ci.intern-source-slice "enum" 0 4))
      (= (compiler-builtin-ctfe "ptr") (ci.intern-source-slice "ptr" 0 3))
      (=
        (compiler-builtin-ctfe "mut-ptr")
        (ci.intern-source-slice "mut-ptr" 0 7))
      (= (compiler-builtin-ctfe "ref") (ci.intern-source-slice "ref" 0 3))
      (=
        (compiler-builtin-ctfe "mut-ref")
        (ci.intern-source-slice "mut-ref" 0 7))
      (= (compiler-builtin-ctfe "region") (ci.intern-source-slice "region" 0 6))
      (=
        (compiler-builtin-ctfe "type-var")
        (ci.intern-source-slice "type-var" 0 8))
      (=
        (compiler-builtin-ctfe ":cleanup")
        (ci.intern-source-slice ":cleanup" 0 8))
      (= (compiler-builtin-ctfe ":owned") (ci.intern-source-slice ":owned" 0 6))
      (=
        (compiler-builtin-ctfe ":lifetimes")
        (ci.intern-source-slice ":lifetimes" 0 10))
      (= (compiler-builtin-ctfe ":repr") (ci.intern-source-slice ":repr" 0 5))
      (=
        (compiler-builtin-ctfe ":packed")
        (ci.intern-source-slice ":packed" 0 7))
      (= (compiler-builtin-ctfe "packed") (ci.intern-source-slice "packed" 0 6))
      (= (compiler-builtin-ctfe "scalar") (ci.intern-source-slice "scalar" 0 6))
      (= (compiler-builtin-ctfe "avx2") (ci.intern-source-slice "avx2" 0 4))
      (= (compiler-builtin-ctfe "avx512") (ci.intern-source-slice "avx512" 0 6))
      (= (compiler-builtin-ctfe "cfg") (ci.intern-source-slice "cfg" 0 3))
      (=
        (compiler-builtin-ctfe "uniform")
        (ci.intern-source-slice "uniform" 0 7))
      (=
        (compiler-builtin-ctfe "varying")
        (ci.intern-source-slice "varying" 0 7))
      (= (compiler-builtin-ctfe "none") (ci.intern-source-slice "none" 0 4))
      (= (compiler-builtin-ctfe "lanes") (ci.intern-source-slice "lanes" 0 5))
      (= (compiler-builtin-ctfe "args") (ci.intern-source-slice "args" 0 4))
      (= (compiler-builtin-ctfe "result") (ci.intern-source-slice "result" 0 6))
      (=
        (compiler-builtin-ctfe "index-param")
        (ci.intern-source-slice "index-param" 0 11))
      (=
        (compiler-builtin-ctfe "specialization")
        (ci.intern-source-slice "specialization" 0 14))
      (=
        (compiler-builtin-ctfe ":export-symbol")
        (ci.intern-source-slice ":export-symbol" 0 14))
      (=
        (compiler-builtin-ctfe ":spmd-callable")
        (ci.intern-source-slice ":spmd-callable" 0 14))
      (=
        (compiler-builtin-ctfe "c-varargs")
        (ci.intern-source-slice "c-varargs" 0 9))
      (= (compiler-builtin-ctfe ":abi") (ci.intern-source-slice ":abi" 0 4))
      (=
        (compiler-builtin-ctfe ":symbol")
        (ci.intern-source-slice ":symbol" 0 7))
      (=
        (compiler-builtin-ctfe ":link-lib")
        (ci.intern-source-slice ":link-lib" 0 9))
      (=
        (compiler-builtin-ctfe ":link-search")
        (ci.intern-source-slice ":link-search" 0 12))
      (=
        (compiler-builtin-ctfe ":link-arg")
        (ci.intern-source-slice ":link-arg" 0 9))
      (= (compiler-builtin-ctfe "as") (ci.intern-source-slice "as" 0 2))
      (= (compiler-builtin-ctfe ":as") (ci.intern-source-slice ":as" 0 3))
      (= (compiler-builtin-ctfe "sum") (ci.intern-source-slice "sum" 0 3))
      (= (compiler-builtin-ctfe "min") (ci.intern-source-slice "min" 0 3))
      (= (compiler-builtin-ctfe "max") (ci.intern-source-slice "max" 0 3))
      (=
        (compiler-builtin-ctfe "defgeneric")
        (ci.intern-source-slice "defgeneric" 0 10))
      (=
        (compiler-builtin-ctfe "generic")
        (ci.intern-source-slice "generic" 0 7))
      (=
        (compiler-builtin-ctfe "deftrait")
        (ci.intern-source-slice "deftrait" 0 8))
      (= (compiler-builtin-ctfe "trait") (ci.intern-source-slice "trait" 0 5))
      (=
        (compiler-builtin-ctfe "interface")
        (ci.intern-source-slice "interface" 0 9))
      (= (compiler-builtin-ctfe "impl") (ci.intern-source-slice "impl" 0 4))
      (= (compiler-builtin-ctfe "where") (ci.intern-source-slice "where" 0 5))
      (=
        (compiler-builtin-ctfe "pattern-binding-typed")
        (ci.intern-source-slice "pattern-binding-typed" 0 21))
      (=
        (compiler-builtin-ctfe "expr-resource-scope")
        (ci.intern-source-slice "expr-resource-scope" 0 19))
      (=
        (compiler-builtin-ctfe "expr-let-scope")
        (ci.intern-source-slice "expr-let-scope" 0 14))
      (=
        (compiler-builtin-ctfe "expr-set-var")
        (ci.intern-source-slice "expr-set-var" 0 12))
      (=
        (compiler-builtin-ctfe "expr-begin-unit")
        (ci.intern-source-slice "expr-begin-unit" 0 15))
      (=
        (compiler-builtin-ctfe "expr-not")
        (ci.intern-source-slice "expr-not" 0 8))
      (=
        (compiler-builtin-ctfe "expr-while")
        (ci.intern-source-slice "expr-while" 0 10))
      (=
        (compiler-builtin-ctfe "syntax-name-fresh")
        (ci.intern-source-slice "syntax-name-fresh" 0 17))
      (=
        (compiler-builtin-ctfe "__tl_dyn-array")
        (ci.intern-source-slice "__tl_dyn-array" 0 14))
      (= (compiler-builtin-ctfe "slice") (ci.intern-source-slice "slice" 0 5))
      (=
        (compiler-builtin-ctfe "expr-borrow")
        (ci.intern-source-slice "expr-borrow" 0 11))
      (=
        (compiler-builtin-ctfe "expr-array-ref")
        (ci.intern-source-slice "expr-array-ref" 0 14))
      (=
        (compiler-builtin-ctfe "expr-replace")
        (ci.intern-source-slice "expr-replace" 0 12))
      (=
        (compiler-builtin-ctfe "module-value-expr")
        (ci.intern-source-slice "module-value-expr" 0 17))
      (=
        (compiler-builtin-ctfe "function-shared-borrow-returns-string?")
        (ci.intern-source-slice "function-shared-borrow-returns-string?" 0 38))
      (=
        (compiler-builtin-ctfe "expr-shared-call1")
        (ci.intern-source-slice "expr-shared-call1" 0 17))
      (=
        (compiler-builtin-ctfe "expr-shared-let-scope")
        (ci.intern-source-slice "expr-shared-let-scope" 0 21))
      (=
        (compiler-builtin-ctfe "type-expr")
        (ci.intern-source-slice "type-expr" 0 9))
      (=
        (compiler-builtin-ctfe "expr-lambda1")
        (ci.intern-source-slice "expr-lambda1" 0 12))
      (=
        (compiler-builtin-ctfe ":ignore")
        (ci.intern-source-slice ":ignore" 0 7))
      (= (compiler-builtin-ctfe ":slow") (ci.intern-source-slice ":slow" 0 5))
      (=
        (compiler-builtin-ctfe ":must-use")
        (ci.intern-source-slice ":must-use" 0 9))
      (=
        (compiler-builtin-ctfe "c-function")
        (ci.intern-source-slice "c-function" 0 10))
      (= (compiler-builtin-ctfe "CFunc") (ci.intern-source-slice "CFunc" 0 5))
      (=
        (compiler-builtin-ctfe "nullable")
        (ci.intern-source-slice "nullable" 0 8))
      (=
        (compiler-builtin-ctfe "non-null")
        (ci.intern-source-slice "non-null" 0 8))
      (=
        (compiler-builtin-ctfe "unsafe-nullable")
        (ci.intern-source-slice "unsafe-nullable" 0 15))
      (=
        (compiler-builtin-ctfe "unsafe-non-null")
        (ci.intern-source-slice "unsafe-non-null" 0 15))
      (not
        (=
          (compiler-builtin-ctfe "all")
          (ci.intern-generated-canonical-name "all")))
      (not
        (=
          (compiler-builtin-ctfe ":cleanup")
          (ci.intern-generated-canonical-name ":cleanup")))
      (not
        (=
          (compiler-builtin-ctfe "cfg")
          (ci.intern-generated-canonical-name "cfg")))
      (not
        (=
          (compiler-builtin-ctfe ":abi")
          (ci.intern-generated-canonical-name ":abi")))
      (not
        (=
          (compiler-builtin-ctfe "as")
          (ci.intern-generated-canonical-name "as")))
      (not
        (=
          (compiler-builtin-ctfe "defgeneric")
          (ci.intern-generated-canonical-name "defgeneric")))
      (not
        (=
          (compiler-builtin-ctfe "__tl_dyn-array")
          (ci.intern-generated-canonical-name "__tl_dyn-array")))
      (not
        (=
          (compiler-builtin-ctfe "slice")
          (ci.intern-generated-canonical-name "slice")))
      (not
        (=
          (compiler-builtin-ctfe ":ignore")
          (ci.intern-generated-canonical-name ":ignore")))
      (not
        (=
          (compiler-builtin-ctfe ":slow")
          (ci.intern-generated-canonical-name ":slow")))
      (not
        (=
          (compiler-builtin-ctfe ":must-use")
          (ci.intern-generated-canonical-name ":must-use"))))))

(cfg
  test
  (define (compiler-builtin-parser-syntax-ids-reset-ok?) : bool
    (begin
      (ci.intern-reset!)
      (compiler-builtin-reset!)
      (compiler-builtin-initialize-for-parse!)
      (unless (compiler-builtin-parser-syntax-ids-current-ok?) (return false))
      (let
        [snapshot : CompilerBuiltinIdsState (state-capture)]
        (begin
          (compiler-builtin-ctfe-set! 219 -1)
          (compiler-builtin-ctfe-set! 233 -1)
          (compiler-builtin-ctfe-set! 234 -1)
          (compiler-builtin-ctfe-set! 271 -1)
          (compiler-builtin-ctfe-set! 279 -1)
          (compiler-builtin-ctfe-set! 280 -1)
          (compiler-builtin-ctfe-set! 281 -1)
          (compiler-builtin-ctfe-set! 282 -1)
          (compiler-builtin-ctfe-set! 283 -1)
          (compiler-builtin-ctfe-set! 284 -1)
          (compiler-builtin-ctfe-set! 285 -1)
          (compiler-builtin-ctfe-set! 286 -1)
          (compiler-builtin-ctfe-set! 287 -1)
          (compiler-builtin-ctfe-set! 288 -1)
          (compiler-builtin-ctfe-set! 289 -1)
          (compiler-builtin-ctfe-set! 290 -1)
          (compiler-builtin-ctfe-set! 291 -1)
          (compiler-builtin-ctfe-set! 292 -1)
          (compiler-builtin-ctfe-set! 293 -1)
          (compiler-builtin-ctfe-set! 294 -1)
          (compiler-builtin-ctfe-set! 295 -1)
          (compiler-builtin-ctfe-set! 296 -1)
          (compiler-builtin-ctfe-set! 297 -1)
          (compiler-builtin-ctfe-set! 298 -1)
          (compiler-builtin-ctfe-set! 299 -1)
          (state-install! snapshot)
          (unless
            (compiler-builtin-parser-syntax-ids-current-ok?)
            (return false))))
      (ci.intern-reset!)
      (compiler-builtin-reset!)
      (compiler-builtin-initialize-for-parse!)
      (compiler-builtin-parser-syntax-ids-current-ok?))))

(cfg
  test
  (test
    compiler-builtin-parser-syntax-ids
    (if (compiler-builtin-parser-syntax-ids-reset-ok?)
      unit
      (io.panic "compiler builtin parser syntax ID lifecycle failed"))))

(cfg
  test
  (define (compiler-builtin-arena-identities-current-ok?) : bool
    (begin
      (compiler-builtin-refresh!)
      (and
        (=
          compiler-builtin-id-arena-module
          (ci.intern-source-slice "stdlib.arena" 0 12))
        (=
          compiler-builtin-id-arena-type
          (ci.intern-source-slice "stdlib.arena/Arena" 0 18))
        (=
          compiler-builtin-id-arena-mark-type
          (ci.intern-source-slice "stdlib.arena/ArenaMark" 0 22))
        (=
          compiler-builtin-id-arena-phase-type
          (ci.intern-source-slice "stdlib.arena/ArenaPhase" 0 23))
        (=
          compiler-builtin-id-arena-make-base
          (ci.intern-source-slice "make" 0 4))
        (=
          compiler-builtin-id-arena-make-atomic-base
          (ci.intern-source-slice "make-atomic" 0 11))
        (=
          compiler-builtin-id-arena-phase-base
          (ci.intern-source-slice "phase" 0 5))
        (=
          compiler-builtin-id-arena-rewind-safe-base
          (ci.intern-source-slice "rewind-safe!" 0 12))
        (=
          compiler-builtin-id-arena-destroy-safe-base
          (ci.intern-source-slice "destroy-safe!" 0 13))
        (not
          (=
            compiler-builtin-id-arena-type
            (ci.intern-generated-canonical-name "stdlib.arena/Arena")))))))

(cfg
  test
  (define (compiler-builtin-arena-identities-snapshot-ok?) : bool
    (let
      [expected : i64 compiler-builtin-id-arena-module]
      [snapshot : CompilerBuiltinIdsState (state-capture)]
      (begin
        (set! compiler-builtin-id-arena-module -1)
        (state-install! snapshot)
        (and
          (= compiler-builtin-id-arena-module expected)
          (compiler-builtin-arena-identities-current-ok?))))))

(cfg
  test
  (define (compiler-builtin-arena-identities-two-state-ok?) : bool
    (let
      [intern-a : ci.InternCompatState (ci.intern-compat-state-new)]
      [intern-b : ci.InternCompatState (ci.intern-compat-state-new)]
      [_a-prefix : i64 (ci.intern-compat-state-intern (&mut intern-a) "a-only")]
      [_b-prefix-1 : i64
        (ci.intern-compat-state-intern (&mut intern-b) "b-only-1")]
      [_b-prefix-2 : i64
        (ci.intern-compat-state-intern (&mut intern-b) "b-only-2")]
      [builtins-a : CompilerBuiltinIdsState (state-new)]
      [builtins-b : CompilerBuiltinIdsState (state-new)]
      [arena-a : i64 -1]
      [arena-b : i64 -1]
      (begin
        (ci.intern-compat-state-install! intern-a)
        (compiler-builtin-reset!)
        (compiler-builtin-initialize-for-parse!)
        (set! arena-a compiler-builtin-id-arena-module)
        (state-capture-from-globals! (&mut builtins-a))
        (ci.intern-compat-state-capture-from-globals! (&mut intern-a))
        (ci.intern-compat-state-install! intern-b)
        (compiler-builtin-reset!)
        (compiler-builtin-initialize-for-parse!)
        (set! arena-b compiler-builtin-id-arena-module)
        (state-capture-from-globals! (&mut builtins-b))
        (ci.intern-compat-state-capture-from-globals! (&mut intern-b))
        (unless (not (= arena-a arena-b)) (return false))
        (ci.intern-compat-state-install! intern-a)
        (state-install! (& builtins-a))
        (unless
          (and
            (= compiler-builtin-id-arena-module arena-a)
            (compiler-builtin-arena-identities-current-ok?))
          (return false))
        (ci.intern-compat-state-install! intern-b)
        (state-install! (& builtins-b))
        (and
          (= compiler-builtin-id-arena-module arena-b)
          (compiler-builtin-arena-identities-current-ok?))))))

(cfg
  test
  (test
    compiler-builtin-arena-identities
    (begin
      (ci.intern-reset!)
      (compiler-builtin-reset!)
      (compiler-builtin-initialize-for-parse!)
      (if (and
        (compiler-builtin-arena-identities-current-ok?)
        (compiler-builtin-arena-identities-snapshot-ok?)
        (compiler-builtin-arena-identities-two-state-ok?))
        unit
        (io.panic "compiler builtin arena identity lifecycle failed")))))

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
      (= name-id compiler-builtin-id-tl-alloc-aligned)
      (compiler-builtin-id-any4?
        name-id
        compiler-builtin-id-tl-arena-make-small
        compiler-builtin-id-tl-arena-make-atomic
        compiler-builtin-id-tl-arena-current
        compiler-builtin-id-tl-arena-set)
      (compiler-builtin-id-any4?
        name-id
        compiler-builtin-id-tl-arena-destroy
        compiler-builtin-id-tl-arena-poison-enable
        compiler-builtin-id-tl-thread-entry-ptr
        compiler-builtin-id-tl-thread-init)
      (compiler-builtin-id-any3?
        name-id
        compiler-builtin-id-tl-arena-debug-protect-never-reset
        compiler-builtin-id-tl-arena-debug-assert-pool-install
        compiler-builtin-id-tl-arena-debug-retire-protected))))

(define (compiler-builtin-backend-runtime-arena-debug-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (compiler-builtin-id-any3?
      name-id
      compiler-builtin-id-tl-arena-debug-protect-never-reset
      compiler-builtin-id-tl-arena-debug-assert-pool-install
      compiler-builtin-id-tl-arena-debug-retire-protected)))

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
        compiler-builtin-id-tl-arena-make-small
        compiler-builtin-id-tl-arena-make-atomic)
      (compiler-builtin-id-any4?
        name-id
        compiler-builtin-id-tl-arena-current
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
    (or
      (= name-id compiler-builtin-id-tl-alloc)
      (= name-id compiler-builtin-id-tl-alloc-aligned))))

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

(define (compiler-builtin-backend-tl-int-to-string-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tl-int-to-string)))

(define (compiler-builtin-backend-fixed-fault-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (or
      (compiler-builtin-id-any3?
        name-id
        compiler-builtin-id-tl-oob-abort
        compiler-builtin-id-tl-div-abort
        compiler-builtin-id-tl-shift-abort)
      (compiler-builtin-id-any3?
        name-id
        compiler-builtin-id-tl-array-fill8
        compiler-builtin-id-tl-array-zero
        compiler-builtin-id-tl-mem-fill8)
      (compiler-builtin-id-any2?
        name-id
        compiler-builtin-id-tl-mem-copy-fwd
        compiler-builtin-id-tl-mem-copy8-fwd))))

(define (compiler-builtin-backend-tl-array-fill8-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tl-array-fill8)))

(define (compiler-builtin-backend-tl-array-zero-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tl-array-zero)))

(define (compiler-builtin-backend-tl-mem-fill8-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tl-mem-fill8)))

(define (compiler-builtin-backend-tl-mem-copy-fwd-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tl-mem-copy-fwd)))

(define (compiler-builtin-backend-tl-mem-copy8-fwd-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tl-mem-copy8-fwd)))

(define (compiler-builtin-backend-tlci-call-macro-entry-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tl-tlci-call-macro-entry)))

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

(define (compiler-builtin-lower-string-length-load-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (compiler-builtin-id-any2?
      name-id
      compiler-builtin-id-length
      compiler-builtin-id-tl-private-string-length)))

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

(define (compiler-builtin-lower-float-sqrt-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tl-private-float-sqrt)))

(define (compiler-builtin-lower-float-to-bits-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tl-private-float-to-bits)))

(define (compiler-builtin-lower-float-from-bits-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-tl-private-float-from-bits)))

(define (compiler-builtin-lower-float-bitcast-id? [name-id : i64]) : bool
  (or
    (compiler-builtin-lower-float-to-bits-id? name-id)
    (compiler-builtin-lower-float-from-bits-id? name-id)))

;: Compiler-private intrinsic spellings whose fallback semantics belong to the
;: module that contains the call, not to a later importing module.  Keeping this
;: set in the fixed-id registry lets typechecking and lowering share the exact
;: same provenance rule.
(define (compiler-builtin-private-intrinsic-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (or
      (compiler-builtin-id-any4?
        name-id
        compiler-builtin-id-tl-private-string-length
        compiler-builtin-id-tl-private-string-ref
        compiler-builtin-id-tl-private-string-eq
        compiler-builtin-id-tl-private-string-to-int)
      (compiler-builtin-id-any3?
        name-id
        compiler-builtin-id-tl-private-float-sqrt
        compiler-builtin-id-tl-private-float-to-bits
        compiler-builtin-id-tl-private-float-from-bits))))

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

(define (compiler-builtin-typecheck-float-sqrt-id? [name-id : i64]) : bool
  (compiler-builtin-lower-float-sqrt-id? name-id))

(define (compiler-builtin-typecheck-float-bitcast-id? [name-id : i64]) : bool
  (compiler-builtin-lower-float-bitcast-id? name-id))

(define (compiler-builtin-typecheck-tls-current-arena-id? [name-id : i64]) : bool
  (compiler-builtin-lower-tls-current-arena-id? name-id))

(define (compiler-builtin-typecheck-tls-current-arena-read-id? [name-id : i64]) : bool
  (compiler-builtin-lower-tls-current-arena-read-id? name-id))

;: Ordinary call spellings whose compiler-owned fallback always requires an
;: unsafe context. Keep the typechecker and syntax-only lint preclassifier on
;: this single list so a newly added atomic/volatile primitive cannot silently
;: make unused-unsafe lint fall back to a whole-program check.
(define (compiler-builtin-typecheck-atomic-pointer-name? [name : String]) : bool
  (or
    (string.eq name "atomic-load")
    (string.eq name "atomic-store!")
    (string.eq name "atomic-add!")
    (string.eq name "atomic-fetch-add!")
    (string.eq name "atomic-cas!")
    (string.eq name "volatile-load")
    (string.eq name "volatile-store!")))

(define (compiler-builtin-typecheck-syntactic-unsafe-call-id? [name-id : i64]) : bool
  (or
    (compiler-builtin-typecheck-atomic-pointer-name? (ci.intern-str name-id))
    (and
      (compiler-builtin-typecheck-tls-current-arena-id? name-id)
      (not (compiler-builtin-typecheck-tls-current-arena-read-id? name-id)))))

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

;: Bare public helper spellings whose fallback becomes visible only when the
;: current module imports `stdlib.string`. The typechecker and syntax-only
;: unused-import classifier share this exact compatibility catalog so ordinary
;: dotted imports never become general flat imports.
(define (compiler-builtin-typecheck-stdlib-string-bare-helper-id?
  [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (or
      (compiler-builtin-id-any4?
        name-id
        compiler-builtin-id-string-length
        compiler-builtin-id-string-ref
        compiler-builtin-id-char-at
        compiler-builtin-id-eq)
      (compiler-builtin-id-any4?
        name-id
        compiler-builtin-id-string-eq
        compiler-builtin-id-string-eq-question
        compiler-builtin-id-string-append
        compiler-builtin-id-string-concat))))

(cfg
  test
  (test
    compiler-builtin-stdlib-string-bare-helper-catalog
    (begin
      (compiler-builtin-refresh!)
      (if (and
        (compiler-builtin-typecheck-stdlib-string-bare-helper-id?
          compiler-builtin-id-string-length)
        (compiler-builtin-typecheck-stdlib-string-bare-helper-id?
          compiler-builtin-id-string-ref)
        (compiler-builtin-typecheck-stdlib-string-bare-helper-id?
          compiler-builtin-id-char-at)
        (compiler-builtin-typecheck-stdlib-string-bare-helper-id?
          compiler-builtin-id-eq)
        (compiler-builtin-typecheck-stdlib-string-bare-helper-id?
          compiler-builtin-id-string-eq)
        (compiler-builtin-typecheck-stdlib-string-bare-helper-id?
          compiler-builtin-id-string-eq-question)
        (compiler-builtin-typecheck-stdlib-string-bare-helper-id?
          compiler-builtin-id-string-append)
        (compiler-builtin-typecheck-stdlib-string-bare-helper-id?
          compiler-builtin-id-string-concat)
        (not
          (compiler-builtin-typecheck-stdlib-string-bare-helper-id?
            compiler-builtin-id-string-to-int))
        (not
          (compiler-builtin-typecheck-stdlib-string-bare-helper-id?
            (ci.intern "trim"))))
        unit
        (io.panic "compiler builtin stdlib.string bare helper catalog failed")))))

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

(define (compiler-builtin-c-fn-check-id? [name-id : i64]) : bool
  (begin
    (compiler-builtin-refresh!)
    (= name-id compiler-builtin-id-c-fn-check)))

(cfg
  test
  (test
    compiler-builtin-c-fn-check-reset
    (begin
      (ci.intern-reset!)
      (compiler-builtin-reset!)
      (compiler-builtin-initialize-for-parse!)
      (compiler-builtin-refresh!)
      (let
        [snapshot : CompilerBuiltinIdsState (state-capture)]
        [check-id : i64 compiler-builtin-id-c-fn-check]
        [abort-id : i64 compiler-builtin-id-tl-c-fn-null-abort]
        (begin
          (set! compiler-builtin-id-c-fn-check -1)
          (set! compiler-builtin-id-tl-c-fn-null-abort -1)
          (state-install! snapshot)
          (if (and
            (compiler-builtin-c-fn-check-id? check-id)
            (= compiler-builtin-id-tl-c-fn-null-abort abort-id)
            (= (state-ref snapshot 321) check-id)
            (= (state-ref snapshot 322) abort-id)
            (string.eq (ci.intern-str check-id) "c-fn-check")
            (string.eq (ci.intern-str abort-id) "tl_c_fn_null_abort"))
            unit
            (io.panic
              "compiler C function check builtin identity lifecycle failed")))))))