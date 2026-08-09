;; Compile-root declaration with the same source spelling but an incompatible
;; signature. The imported module's local declaration must shadow it there.
;; Eight distinct imports force the module-local view past the explicit cache
;; boundary that exposed the compile-root leak. They are intentionally unused.
(import stdlib.io as _padding_io)
(import stdlib.string as _padding_string)
(import stdlib.array as _padding_array)
(import stdlib.arena as _padding_arena)
(import stdlib.hash as _padding_hash)
(import stdlib.byte_buf_core as _padding_byte_buf)
(import stdlib.option as _padding_option)
(import stdlib.text_buf as _padding_text_buf)
(import macro_module_local_shadow_provider as provider)
(import stdlib.str_cat_runtime as _padding_str_cat)

(defenum MacroModuleLocalShadowTarget
  (Linux)
  (Windows))

(define (macro-module-local-shadow-value
  [_target : MacroModuleLocalShadowTarget]
  [value : String]) : String
  value)

(define (main) : i64
  (provider.macro-module-local-shadow-answer))