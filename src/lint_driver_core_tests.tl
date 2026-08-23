;; lint_driver_core_tests.tl - Lint driver self-test fixtures and entries
;; split from production lint_driver_core.tl (simplify.md A1, #5169 pattern).
;;
;; Main-less companion imported by src/tests/lint_driver_smoke.tl: it holds
;; the selfhost-lint-*-source fixture getters, the fixture-decls builders, the
;; finding helpers, and the six lint driver self-test entries. The production
;; module keeps the lint driver itself.
(import stdlib.str_cat_runtime as str_cat)
(import lint_driver_core)
(import lint_core)
(import stdlib.io)
(import stdlib.byte_buf)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as lint_svec)
(import compiler_ast_types as ast)
(import compiler_load)
(import package_source_core)
(import compiler_owned_view as owned_view)

(define (selfhost-lint-write-text [path : String] [contents : String]) : unit
  (io.write-file path (byte_buf.str-as-bytes (& contents))))

;; ---- self-test (driven by lint_driver_smoke.tl) ----
;; A five-deep value-dispatch if-ladder. The nested-if-ladder rule is active, so
;; this emits one finding at the ladder head.
(define (selfhost-lint-ladder-source) : String
  "(define (classify [x : i64]) : i64
  (if (= x 0)
    10
    (if (= x 1)
      20
      (if (= x 2)
        30
        (if (= x 3)
          40
          (if (= x 4)
            50
            0))))))")

(define (selfhost-lint-guard-ladder-source) : String
  "(define (check [a : bool] [b : bool] [c : bool]) : i64
  (begin
    (if a
      (return 1)
      (if b
        (return 2)
        (if c
          (return 3)
          unit)))
    42))")

;; Same ladder, but with a `;; lint-allow: nested-if-ladder` directive that
;; suppresses the ladder finding via its stable rule id.
(define (selfhost-lint-suppressed-ladder-source) : String
  "(define (classify [x : i64]) : i64
  ;; lint-allow: nested-if-ladder
  (if (= x 0)
    10
    (if (= x 1)
      20
      (if (= x 2)
        30
        0))))")

;; A directive for a different rule id does not suppress the ladder finding, so
;; this still emits one.
(define (selfhost-lint-wrong-allow-ladder-source) : String
  "(define (classify [x : i64]) : i64
  ;; lint-allow: other-rule
  (if (= x 0)
    10
    (if (= x 1)
      20
      (if (= x 2)
        30
        0))))")

(define (selfhost-lint-all-exit-ladder-source) : String
  "(define (classify [x : i64]) : i64
  (if (= x 0)
    (return 10)
    (if (= x 1)
      (return 20)
      (if (= x 2)
        (return 30)
        (return 0)))))")

(define (selfhost-lint-return-path-chain-source) : String
  "(define (check [a : bool] [b : bool] [c : bool]) : i64
  (if a
    (if b
      (if c
        42
        3)
      2)
    1))")

(define (selfhost-lint-suppressed-return-path-chain-source) : String
  "(define (check [a : bool] [b : bool] [c : bool]) : i64
  ;; lint-allow: return-path-chain
  (if a
    (if b
      (if c
        42
        3)
      2)
    1))")

(define (selfhost-lint-unit-if-source) : String
  "(define (check [ok : bool]) : i64
  (begin
    (if ok
      (return 1)
      unit)
    42))")

(define (selfhost-lint-unit-set-source) : String
  "(define (check [ok : bool]) : i64
  (let
    [seen : bool true]
    (begin
      (if (not ok)
        unit
        (set! seen false))
      (if seen 42 0))))")

(define (selfhost-lint-suppressed-unit-if-source) : String
  "(define (check [ok : bool]) : i64
  (begin
    ;; lint-allow: unit-if-guard
    (if ok
      (return 1)
      unit)
    42))")

(define (selfhost-lint-when-unless-source) : String
  "(define (check [a : bool] [b : bool]) : i64
  (begin
    (when a (return 1))
    (unless b (return 2))
    42))")

(define (selfhost-lint-redundant-divergence-padding-source) : String
  "(define (main [flag : bool]) : i64
  (begin
    (begin
      (io.panic \"stop\")
      ;; lint-allow: unreachable-code
      0)
    (unsafe
      (io.error \"stop\")
      ;; lint-allow: unreachable-code
      1)
    (with-arena scratch
      (io.panic \"stop\")
      ;; lint-allow: unreachable-code
      2)
    (if flag
      (begin
        (io.panic \"stop\")
        ;; lint-allow: unreachable-code
        3)
      4)))")

(define (selfhost-lint-clean-divergence-source) : String
  "(define (main [flag : bool]) : i64
  (if flag
    (io.panic \"stop\")
    4))")

(define (selfhost-lint-suppressed-divergence-padding-source) : String
  "(define (main) : i64
  (begin
    ;; lint-allow: redundant-divergence-padding
    (io.panic \"stop\")
    ;; lint-allow: unreachable-code
    0))")

;; A clean source with no nested-`if` ladder - zero findings.
(define (selfhost-lint-clean-source) : String
  "(define (inc [x : i64]) : i64 (+ x 1))")

(define (selfhost-lint-unused-dotted-import-source) : String
  "(import pkg.data)
(define (main) : i64 42)")

(define (selfhost-lint-used-dotted-import-alias-source) : String
  "(import pkg.data)
(define (main) : i64 (data.value))")

(define (selfhost-lint-used-dotted-import-full-path-source) : String
  "(import pkg.data)
(define (main) : i64 (pkg.data.value))")

(define (selfhost-lint-unused-explicit-import-alias-source) : String
  "(import pkg.data as d)
(define (main) : i64 42)")

(define (selfhost-lint-used-explicit-import-alias-source) : String
  "(import pkg.data as d)
(define (main) : i64 (d.value))")

(define (selfhost-lint-unused-underscore-import-source) : String
  "(import pkg.data as _data)
(define (main) : i64 42)")

(define (selfhost-lint-used-import-type-source) : String
  "(import pkg.data)
(define (make) : data.Item (init : data.Item))")

(define (selfhost-lint-used-import-pattern-source) : String
  "(import pkg.data)
(define (read [x : data.Maybe]) : i64
  (match x
    [(data.Maybe.Some y) y]
    [_ 0]))")

(define (selfhost-lint-used-import-macro-call-source) : String
  "(import pkg.macros)
(pkg.macros.emit i64)")

(define (selfhost-lint-used-import-macro-alias-source) : String
  "(import stdlib.core_macros as core)
(define (check [flag : bool]) : bool (core/and flag true))")

(define (selfhost-lint-stdlib-string-bare-helpers-source) : String
  "(import stdlib.string)
(define (main) : i64
  (begin
    (string-length \"abc\")
    (string-ref \"abc\" 0)
    (char-at \"abc\" 0)
    (eq \"a\" \"b\")
    (string-eq \"a\" \"b\")
    (string=? \"a\" \"b\")
    (string-append \"a\" \"b\")
    (string-concat \"a\" \"b\")
    42))")

(define (selfhost-lint-stdlib-string-bare-explicit-alias-source) : String
  "(import stdlib.string as s)
(define (main) : i64 (string-length \"abc\"))")

(define (selfhost-lint-stdlib-string-bare-top-level-shadow-source) : String
  "(import stdlib.string)
(define (string-length [text : String]) : i64 1)
(define (main) : i64 (string-length \"abc\"))")

(define (selfhost-lint-stdlib-string-bare-param-shadow-source) : String
  "(import stdlib.string)
(define (main [string-length : (-> String i64)]) : i64
  (string-length \"abc\"))")

(define (selfhost-lint-stdlib-string-bare-let-shadow-source) : String
  "(import stdlib.string)
(define (main) : i64
  (let
    [string-length : (-> String i64)
      (lambda ([text : String]) : i64 1)]
    (string-length \"abc\")))")

(define (selfhost-lint-stdlib-string-bare-lambda-shadow-source) : String
  "(import stdlib.string)
(define (main) : i64
  ((lambda ([string-length : (-> String i64)]) : i64
    (string-length \"abc\"))
   (lambda ([text : String]) : i64 1)))")

(define (selfhost-lint-stdlib-string-bare-trim-source) : String
  "(import stdlib.string)
(define (main) : String (trim \" abc \"))")

(define (selfhost-lint-stdlib-string-removed-bare-helper-source) : String
  "(import stdlib.string)
(define (main) : i64 (string->int \"42\"))")

(define (selfhost-lint-stdlib-string-other-module-shadow-source) : String
  "(module first)
(import stdlib.string)
(define (main) : i64 (string-length \"abc\"))
(module second)
(define (string-length) : i64 42)")

(define (selfhost-lint-stdlib-string-other-module-use-source) : String
  "(module first)
(import stdlib.string)
(define (main) : i64 42)
(module second)
(define (other) : i64 (string-length \"abc\"))")

(define (selfhost-lint-suppressed-unused-import-source) : String
  ";; lint-allow: unused-import
(import pkg.data)
(define (main) : i64 42)")

(define (selfhost-lint-package-dead-source-a) : String
  "(define (main) : i64 (pkg.public-api 1))
(define (public-api [x : i64]) : i64 (helper x))
(define (helper [x : i64]) : i64 (cross-file-helper x))
(define (default-visible-helper) : i64 1)
;; lint-allow: dead-code
(define (suppressed-visible-helper) : i64 2)")

(define (selfhost-lint-package-dead-source-b) : String
  (str_cat.str-cat
    "(define (cross-file-helper [x : i64]) : i64 (+ x 1))
(define (test-only-helper) : i64 3)
"
    "(cfg test (te"
    "st \"test-only\" (test-only-helper)))"))

(define (selfhost-lint-package-dead-entry-source) : String
  "(define (main) : i64 42)
(define (test-reached-helper) : i64 7)
(define (unused-entry-helper) : i64 9)")

(define (selfhost-lint-package-dead-test-root-source) : String
  "(define (main) : i64 (test-reached-helper))")

(define (selfhost-lint-package-dead-manifest-root-source) : String
  "(define (manifest-entry) : i64 (manifest-helper))
(define (manifest-helper) : i64 7)
(define (manifest-unused) : i64 9)")

(define (selfhost-lint-package-dead-manifest-root-manifest) : String
  "case|lint-root-fixture|src/manifest_api.tl|assembly|skip|direct
lint-root|manifest-entry
contains|_tl_manifest_entry:
end
")

(define (selfhost-lint-package-dead-explicit-root-source) : String
  "(define (retained-api-with-extra) : i64 1)
;; lint-allow: dead-code
(define (retained-api) : i64 (retained-helper))
(define (retained-helper) : i64 7)
(define (explicit-unused) : i64 9)")

(define (selfhost-lint-package-dead-cfg-source) : String
  "(define (main) : i64
  (+ (cfg scratch-vreg (scratch-vreg-helper) 40)
     (+ (cfg embedded-stdlib-tlci (embedded-helper) 1)
        (cfg compile-profile
          (profile-mode-helper)
          (ordinary-mode-helper)))))
(cfg scratch-vreg
  (define (scratch-vreg-helper) : i64 7))
(cfg scratch-vreg
  (define (scratch-vreg-unused) : i64 8))
(cfg embedded-stdlib-tlci
  (define (embedded-helper) : i64 1))
(cfg embedded-stdlib-tlci
  (define (embedded-unused) : i64 2))
(cfg compile-profile
  (define (profile-helper) : i64 1))
(cfg compile-profile-summary
  (define (profile-summary-helper) : i64 1))
(cfg compile-profile
  (define (profile-mode-helper) : i64
    (cfg compile-profile-summary
      (profile-summary-helper)
      (profile-helper))))
(cfg compile-profile
  (define (profile-unused) : i64 2))
(cfg lint-fixture-experimental
  (define (experimental-helper) : i64 9))
(define (ordinary-mode-helper) : i64 1)
(define (ordinary-unused) : i64 0)")

(define (selfhost-lint-package-dead-qualified-left-source) : String
  "(module left)
(define (helper) : i64 1)")

(define (selfhost-lint-package-dead-qualified-right-source) : String
  "(module right)
(define (live) : i64 (helper))
(define (helper) : i64 2)")

(define (selfhost-lint-package-dead-qualified-main-source) : String
  "(module main)
(import left)
(import right)
(define (main) : i64 (right.live))")

(define (selfhost-lint-package-dead-moduleless-left-source) : String
  "(define (live) : i64 (helper))
(define (helper) : i64 1)
(define (unused) : i64 11)")

(define (selfhost-lint-package-dead-moduleless-right-source) : String
  "(define (live) : i64 (helper))
(define (helper) : i64 2)
(define (unused) : i64 12)")

(define (selfhost-lint-package-dead-moduleless-main-source) : String
  "(import pkg.left as first)
(import pkg.right as second)
(define (main) : i64 (+ (first.live) (second.live)))")

(define (selfhost-lint-unused-assignment-init-source) : String
  "(define (main) : i64
  (let
    [x : i64 1]
    (begin
      (set! x 2)
      x)))")

(define (selfhost-lint-unused-assignment-set-source) : String
  "(define (main) : i64
  (let
    [x : i64 0]
    (begin
      (set! x (+ x 1))
      (set! x 2)
      x)))")

(define (selfhost-lint-used-before-overwrite-source) : String
  "(define (main) : i64
  (let
    [x : i64 1]
    (begin
      (set! x (+ x 1))
      x)))")

(define (selfhost-lint-branch-conservative-assignment-source) : String
  "(define (main [flag : bool]) : i64
  (let
    [x : i64 1]
    (begin
      (if flag
        (set! x 2)
        unit)
      (set! x 3)
      x)))")

(define (selfhost-lint-underscore-assignment-source) : String
  "(define (main) : i64
  (let
    [_x : i64 1]
    (begin
      (set! _x 2)
      _x)))")

(define (selfhost-lint-suppressed-unused-assignment-source) : String
  "(define (main) : i64
  (let
    ;; lint-allow: unused-assignment
    [x : i64 1]
    (begin
      (set! x 2)
      x)))")

(define (selfhost-lint-single-element-array-fixed-source) : String
  "(define (main) : i64
  (let
    [cur : (Array i64 1) (array 0)]
    (begin
      (set! (array-ref cur 0) 3)
      (array-ref cur 0))))")

(define (selfhost-lint-single-element-array-param-source) : String
  "(define (read-cell [cur : (Array i64 1)]) : i64
  (array-ref cur 0))")

(define (selfhost-lint-single-element-array-dynamic-source) : String
  "(define (main) : i64
  (let
    [cur : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    (begin
      (set! (array-ref cur 0) 3)
      (array-ref cur 0))))")

(define (selfhost-lint-single-element-array-dotted-source) : String
  "(define (main) : i64
  (let
    [cur : (__tl_dyn-array i64) (array.make-array i64 1)]
    (begin
      (set! (array-ref cur 0) 3)
      (array.ref cur 0))))")

(define (selfhost-lint-single-element-array-nonzero-source) : String
  "(define (main) : i64
  (let
    [cur : (Array i64 2) (array 1 2)]
    (array-ref cur 1)))")

(define (selfhost-lint-single-element-array-dynamic-index-source) : String
  "(define (main [index : i64]) : i64
  (let
    [cur : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    (array-ref cur index)))")

(define (selfhost-lint-single-element-array-escape-source) : String
  "(define (use-array [items : (__tl_dyn-array i64)]) : i64
  (array-length items))
(define (main) : i64
  (let
    [cur : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    (use-array cur)))")

(define (selfhost-lint-single-element-array-aggregate-source) : String
  "(define (main) : String
  (let
    [cur : (Array String 1) (array \"x\")]
    (array-ref cur 0)))")

(define (selfhost-lint-single-element-array-suppressed-source) : String
  "(define (main) : i64
  (let
    ;; lint-allow: single-element-array-cell
    [cur : (Array i64 1) (array 0)]
    (array-ref cur 0)))")

(define (selfhost-lint-dynamic-array-literal-dotted-source) : String
  "(define (make-items [a : i64] [b : i64] [c : i64]) : (__tl_dyn-array i64)
  (let
    [items : (__tl_dyn-array i64) (array.make-array i64 3)]
    (begin
      (set! (array-ref items 0) a)
      (set! (array-ref items 1) b)
      (set! (array-ref items 2) c)
      items)))")

(define (selfhost-lint-dynamic-array-literal-private-source) : String
  "(define (make-items) : (__tl_dyn-array i64)
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    (begin
      (set! (array-ref items 0) 4)
      (set! (array-ref items 1) 7)
      items)))")

(define (selfhost-lint-dynamic-array-literal-return-source) : String
  "(define (make-items) : (__tl_dyn-array i64)
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    (begin
      (set! (array-ref items 0) 4)
      (set! (array-ref items 1) 7)
      (return items))))")

(define (selfhost-lint-dynamic-array-literal-assignment-source) : String
  "(define (set-items [result : (__tl_dyn-array i64)]) : unit
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    (begin
      (set! (array-ref items 0) 4)
      (set! (array-ref items 1) 7)
      (set! result items))))")

(define (selfhost-lint-dynamic-array-literal-ambiguous-two-var-source) : String
  "(define (make-items [first : i64] [second : i64]) : (__tl_dyn-array i64)
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    (begin
      (set! (array-ref items 0) first)
      (set! (array-ref items 1) second)
      items)))")

(define (selfhost-lint-dynamic-array-literal-read-before-complete-source) : String
  "(define (make-items) : (__tl_dyn-array i64)
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    (begin
      (set! (array-ref items 0) 4)
      (array-ref items 0)
      (set! (array-ref items 1) 7)
      items)))")

(define (selfhost-lint-dynamic-array-literal-computed-index-source) : String
  "(define (make-items [index : i64]) : (__tl_dyn-array i64)
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    (begin
      (set! (array-ref items index) 4)
      (set! (array-ref items 1) 7)
      items)))")

(define (selfhost-lint-dynamic-array-literal-duplicate-index-source) : String
  "(define (make-items) : (__tl_dyn-array i64)
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 3)]
    (begin
      (set! (array-ref items 0) 4)
      (set! (array-ref items 0) 7)
      (set! (array-ref items 2) 9)
      items)))")

(define (selfhost-lint-dynamic-array-literal-gapped-index-source) : String
  "(define (make-items) : (__tl_dyn-array i64)
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 3)]
    (begin
      (set! (array-ref items 0) 4)
      (set! (array-ref items 2) 7)
      (set! (array-ref items 1) 9)
      items)))")

(define (selfhost-lint-dynamic-array-literal-partial-source) : String
  "(define (make-items) : (__tl_dyn-array i64)
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    (begin
      (set! (array-ref items 0) 4)
      items)))")

(define (selfhost-lint-dynamic-array-literal-escape-source) : String
  "(define (consume [items : (__tl_dyn-array i64)]) : unit unit)
(define (make-items) : (__tl_dyn-array i64)
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    (begin
      (set! (array-ref items 0) 4)
      (consume items)
      (set! (array-ref items 1) 7)
      items)))")

(define (selfhost-lint-dynamic-array-literal-suppressed-source) : String
  "(define (make-items) : (__tl_dyn-array i64)
  (let
    ;; lint-allow: prefer-dynamic-array-literal
    [items : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    (begin
      (set! (array-ref items 0) 4)
      (set! (array-ref items 1) 7)
      items)))")

(define (selfhost-lint-nested-let-source) : String
  "(define (main) : i64
  (let
    [a : i64 1]
    (let
      [b : i64 (+ a 1)]
      (+ a b))))")

(define (selfhost-lint-shadowing-nested-let-source) : String
  "(define (main) : i64
  (let
    [a : i64 1]
    (let
      [a : i64 (+ a 1)]
      a)))")

(define (selfhost-lint-begin-inner-let-source) : String
  "(define (main) : i64
  (let
    [a : i64 1]
    (begin
      (let [b : i64 (+ a 1)] b)
      a)))")

(define (selfhost-lint-suppressed-nested-let-source) : String
  "(define (main) : i64
  ;; lint-allow: nested-let
  (let
    [a : i64 1]
    (let
      [b : i64 (+ a 1)]
      (+ a b))))")

(define (selfhost-lint-single-begin-source) : String
  "(define (main) : i64
  (begin 42))")

(define (selfhost-lint-clean-begin-source) : String
  "(define (main) : i64
  (begin
    unit
    42))")

(define (selfhost-lint-cfg-begin-source) : String
  "(define (main) : i64
  (begin
    (cfg compile-profile (io.panic \"profile\"))
    42))")

(define (selfhost-lint-suppressed-single-begin-source) : String
  "(define (main) : i64
  ;; lint-allow: single-begin
  (begin 42))")

(define (selfhost-lint-cascading-and-source) : String
  "(define (check [a : bool] [b : bool] [c : bool]) : bool
  (and a (and b c)))")

(define (selfhost-lint-cascading-or-source) : String
  "(define (check [a : bool] [b : bool] [c : bool]) : bool
  (or (or a b) c))")

(define (selfhost-lint-cascading-core-and-source) : String
  "(define (check [a : bool] [b : bool] [c : bool]) : bool
  (and a (and b c)))")

(define (selfhost-lint-flat-and-source) : String
  "(define (check [a : bool] [b : bool] [c : bool]) : bool
  (and a b c))")

(define (selfhost-lint-mixed-and-or-source) : String
  "(define (check [a : bool] [b : bool] [c : bool]) : bool
  (and a (or b c)))")

(define (selfhost-lint-suppressed-cascading-and-source) : String
  "(define (check [a : bool] [b : bool] [c : bool]) : bool
  ;; lint-allow: cascading-and-or
  (and a (and b c)))")

(define (selfhost-lint-transitional-core-macro-source) : String
  "(define (check [flag : bool]) : i64
  (begin
    (core.when flag unit)
    (core.unless false unit)
    (if (core.and flag (core.or false true))
      (if (core.cond [flag true] [else false]) 42 1)
      1)))")

(define (selfhost-lint-clean-core-macro-text-source) : String
  ";; core.cond in a comment is not an expression call head.
(import stdlib.core_macros as core)
(define core-dot-cond-text : String \"core.cond\")
(define (main) : i64
  (let
    [value : i64 core.cond]
    value))")

(define (selfhost-lint-suppressed-transitional-core-macro-source) : String
  "(define (main) : i64
  ;; lint-allow: transitional-core-macro-qualifier
  (if (core.cond [true true] [else false]) 42 1))")

(define (selfhost-lint-two-findings-source) : String
  "(define (first [x : i64]) : i64
  (if (= x 0)
    0
    (if (= x 1)
      1
      (if (= x 2)
        2
        3))))

(define (second [x : i64]) : i64
  (if (= x 0)
    10
    (if (= x 1)
      20
      (if (= x 2)
        30
        40))))")

;; Number of findings reported for `source` (after derived-form-origin +
;; suppression filtering), via the public source-lint path.
(define (selfhost-lint-source-finding-count [source : String]) : i64
  (lint_core.lint-findings-count
    (lint_driver_core.selfhost-lint-source-with-roots
      "lint_driver_self_test.tl"
      source
      (lint_svec.new))))

(define (selfhost-lint-findings-rule-count-from
  [findings : lint_core.LintFindings]
  [rule-id : String]
  [index : i64]
  [count : i64]) : i64
  (if (>=
    index
    (lint_core.lint-findings-count
      (owned_view.compiler-owned-shared-view findings)))
    count
    (match (lint_core.lint-findings-get
      (owned_view.compiler-owned-shared-view findings)
      index)
      [(lint_core.LintMaybeFinding.Some finding)
        (selfhost-lint-findings-rule-count-from
          (owned_view.compiler-owned-shared-view findings)
          (owned_view.compiler-owned-shared-view rule-id)
          (+ index 1)
          (if (string.eq
            finding.rule-id
            (owned_view.compiler-owned-shared-view rule-id))
            (+ count 1)
            count))]
      [(lint_core.LintMaybeFinding.No)
        (selfhost-lint-findings-rule-count-from
          (owned_view.compiler-owned-shared-view findings)
          rule-id
          (+ index 1)
          count)])))

(define (selfhost-lint-findings-rule-count
  [findings : lint_core.LintFindings]
  [rule-id : String]) : i64
  (selfhost-lint-findings-rule-count-from findings rule-id 0 0))

(define (selfhost-lint-source-rule-count [source : String] [rule-id : String]) : i64
  (selfhost-lint-findings-rule-count
    (lint_driver_core.selfhost-lint-source-with-roots
      "lint_driver_self_test.tl"
      source
      (lint_svec.new))
    rule-id))

(define (selfhost-lint-source-unused-import-count [source : String]) : i64
  (selfhost-lint-source-rule-count
    source
    (lint_core.lint-rule-unused-import-id)))

(define (selfhost-lint-unused-import-finding-ok?
  [findings : lint_core.LintFindings]) : bool
  (match (lint_core.lint-findings-get
    (owned_view.compiler-owned-shared-view findings)
    0)
    [(lint_core.LintMaybeFinding.Some finding)
      (let
        [fspan : ast.AstSourceSpan finding.span]
        (and
          (=
            (lint_core.lint-findings-count
              (owned_view.compiler-owned-shared-view findings))
            1)
          (> (ast.ast-source-span-start-line fspan) 0)
          (string.eq finding.rule-id (lint_core.lint-rule-unused-import-id))))]
    [(lint_core.LintMaybeFinding.No) false]))

(define (selfhost-lint-unused-imports-self-test) : i64
  (let
    [unused : lint_core.LintFindings
      (lint_driver_core.selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-unused-dotted-import-source)
        (lint_svec.new))]
    [unused-explicit-alias : lint_core.LintFindings
      (lint_driver_core.selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-unused-explicit-import-alias-source)
        (lint_svec.new))]
    (cond
      [(not (selfhost-lint-unused-import-finding-ok? unused)) 30]
      [(not (selfhost-lint-unused-import-finding-ok? unused-explicit-alias)) 31]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-used-dotted-import-alias-source))
            0))
        32]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-used-dotted-import-full-path-source))
            0))
        33]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-used-explicit-import-alias-source))
            0))
        34]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-unused-underscore-import-source))
            0))
        35]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-used-import-type-source))
            0))
        37]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-used-import-pattern-source))
            0))
        38]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-used-import-macro-call-source))
            0))
        40]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-suppressed-unused-import-source))
            0))
        41]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-used-import-macro-alias-source))
            0))
        43]
      [(not
          (=
            (selfhost-lint-source-unused-import-count
              (selfhost-lint-stdlib-string-bare-helpers-source))
            0))
        44]
      [(not
          (=
            (selfhost-lint-source-unused-import-count
              (selfhost-lint-stdlib-string-bare-explicit-alias-source))
            0))
        45]
      [(not
          (=
            (selfhost-lint-source-unused-import-count
              (selfhost-lint-stdlib-string-bare-top-level-shadow-source))
            1))
        46]
      [(not
          (=
            (selfhost-lint-source-unused-import-count
              (selfhost-lint-stdlib-string-bare-param-shadow-source))
            1))
        47]
      [(not
          (=
            (selfhost-lint-source-unused-import-count
              (selfhost-lint-stdlib-string-bare-let-shadow-source))
            1))
        48]
      [(not
          (=
            (selfhost-lint-source-unused-import-count
              (selfhost-lint-stdlib-string-bare-lambda-shadow-source))
            1))
        49]
      [(not
          (=
            (selfhost-lint-source-unused-import-count
              (selfhost-lint-stdlib-string-bare-trim-source))
            1))
        50]
      [(not
          (=
            (selfhost-lint-source-unused-import-count
              (selfhost-lint-stdlib-string-removed-bare-helper-source))
            1))
        51]
      [(not
          (=
            (selfhost-lint-source-unused-import-count
              (selfhost-lint-stdlib-string-other-module-shadow-source))
            0))
        52]
      [(not
          (=
            (selfhost-lint-source-unused-import-count
              (selfhost-lint-stdlib-string-other-module-use-source))
            1))
        53]
      [(not
          (and
            (lint_core.lint-stdlib-string-module-name?
              "C:/repo/stdlib/string.tl")
            (lint_core.lint-stdlib-string-module-name?
              "C:\\repo\\stdlib\\string.tl")
            (not
              (lint_core.lint-stdlib-string-module-name?
                "C:/repo/other/string.tl"))))
        54]
      [else 42])))

(define (selfhost-lint-package-dead-code-fixture-decls
  [source-a : String]
  [source-b : String]
  [kind : compiler_load.CompilerPkgKind]) : lint_driver_core.SelfhostLintDeadDecls
  (let
    [visible-root : bool
      (lint_driver_core.selfhost-lint-package-dead-visible-root? kind)]
    [reportable : bool
      (lint_driver_core.selfhost-lint-package-dead-reportable? kind)]
    [scan-a : lint_driver_core.SelfhostLintDeadScan
      (lint_driver_core.selfhost-lint-dead-scan-source
        (lint_driver_core.SelfhostLintDeadScan
          (lint_driver_core.selfhost-lint-dead-decls-empty)
          (lint_svec.new))
        "pkg/a.tl"
        source-a
        visible-root
        reportable)]
    [scan-b : lint_driver_core.SelfhostLintDeadScan
      (lint_driver_core.selfhost-lint-dead-scan-source
        scan-a
        "pkg/b.tl"
        source-b
        visible-root
        reportable)]
    [scan : lint_driver_core.SelfhostLintDeadScan
      (lint_driver_core.selfhost-lint-package-dead-add-kind-roots scan-b kind)]
    (lint_driver_core.selfhost-lint-dead-mark-roots-from
      scan.decls
      scan.roots
      0)))

(define (selfhost-lint-package-dead-code-test-root-fixture-decls) : lint_driver_core.SelfhostLintDeadDecls
  (let
    [entry-source : String (selfhost-lint-package-dead-entry-source)]
    [test-source : String (selfhost-lint-package-dead-test-root-source)]
    [scan-entry : lint_driver_core.SelfhostLintDeadScan
      (lint_driver_core.selfhost-lint-dead-scan-source
        (lint_driver_core.SelfhostLintDeadScan
          (lint_driver_core.selfhost-lint-dead-decls-empty)
          (lint_svec.new))
        "pkg/src/main.tl"
        entry-source
        false
        true)]
    [scan-test : lint_driver_core.SelfhostLintDeadScan
      (lint_driver_core.selfhost-lint-dead-scan-source
        scan-entry
        "pkg/src/tests/entry_smoke.tl"
        test-source
        false
        false)]
    [scan : lint_driver_core.SelfhostLintDeadScan
      (lint_driver_core.selfhost-lint-package-dead-add-kind-roots
        scan-test
        CompilerPkgKindBin)]
    (lint_driver_core.selfhost-lint-dead-mark-roots-from
      scan.decls
      scan.roots
      0)))

(define (selfhost-lint-package-dead-code-manifest-root-fixture-decls) : lint_driver_core.SelfhostLintDeadDecls
  (let
    [manifest-dir : String "pkg"]
    [path : String
      (compiler_load.compiler-load-normalize-path
        (compiler_load.compiler-load-join-root-path
          (owned_view.compiler-owned-shared-view manifest-dir)
          "src/manifest_api.tl"))]
    [source : String (selfhost-lint-package-dead-manifest-root-source)]
    [roots : lint_svec.Vec
      (lint_driver_core.selfhost-lint-dead-manifest-roots
        (selfhost-lint-package-dead-manifest-root-manifest)
        manifest-dir)]
    [scan-source : lint_driver_core.SelfhostLintDeadScan
      (lint_driver_core.selfhost-lint-dead-scan-source
        (lint_driver_core.SelfhostLintDeadScan
          (lint_driver_core.selfhost-lint-dead-decls-empty)
          (lint_svec.new))
        path
        source
        false
        true)]
    [scan : lint_driver_core.SelfhostLintDeadScan
      (lint_driver_core.selfhost-lint-dead-scan-add-roots scan-source roots)]
    (lint_driver_core.selfhost-lint-dead-mark-roots-from
      scan.decls
      scan.roots
      0)))

(define (selfhost-lint-package-dead-code-explicit-root-fixture-decls) : lint_driver_core.SelfhostLintDeadDecls
  (let
    [source : String (selfhost-lint-package-dead-explicit-root-source)]
    [scan-source : lint_driver_core.SelfhostLintDeadScan
      (lint_driver_core.selfhost-lint-dead-scan-source
        (lint_driver_core.SelfhostLintDeadScan
          (lint_driver_core.selfhost-lint-dead-decls-empty)
          (lint_svec.new))
        "pkg/explicit_api.tl"
        source
        false
        true)]
    [scan : lint_driver_core.SelfhostLintDeadScan
      (lint_driver_core.selfhost-lint-package-dead-add-kind-roots
        scan-source
        CompilerPkgKindBin)]
    (lint_driver_core.selfhost-lint-dead-mark-roots-from
      scan.decls
      scan.roots
      0)))

(define (selfhost-lint-package-dead-code-cfg-fixture-decls) : lint_driver_core.SelfhostLintDeadDecls
  (let
    [source : String (selfhost-lint-package-dead-cfg-source)]
    [scan-source : lint_driver_core.SelfhostLintDeadScan
      (lint_driver_core.selfhost-lint-dead-scan-source
        (lint_driver_core.SelfhostLintDeadScan
          (lint_driver_core.selfhost-lint-dead-decls-empty)
          (lint_svec.new))
        "pkg/cfg.tl"
        source
        false
        true)]
    [scan : lint_driver_core.SelfhostLintDeadScan
      (lint_driver_core.selfhost-lint-package-dead-add-kind-roots
        scan-source
        CompilerPkgKindBin)]
    (lint_driver_core.selfhost-lint-dead-mark-roots-from
      scan.decls
      scan.roots
      0)))

(define (selfhost-lint-package-dead-qualified-import-fixture-decls) : lint_driver_core.SelfhostLintDeadDecls
  (let
    [left-source : String (selfhost-lint-package-dead-qualified-left-source)]
    [right-source : String (selfhost-lint-package-dead-qualified-right-source)]
    [main-source : String (selfhost-lint-package-dead-qualified-main-source)]
    [scan-left : lint_driver_core.SelfhostLintDeadScan
      (lint_driver_core.selfhost-lint-dead-scan-source
        (lint_driver_core.SelfhostLintDeadScan
          (lint_driver_core.selfhost-lint-dead-decls-empty)
          (lint_svec.new))
        "pkg/left.tl"
        left-source
        false
        true)]
    [scan-right : lint_driver_core.SelfhostLintDeadScan
      (lint_driver_core.selfhost-lint-dead-scan-source
        scan-left
        "pkg/right.tl"
        right-source
        false
        true)]
    [scan-main : lint_driver_core.SelfhostLintDeadScan
      (lint_driver_core.selfhost-lint-dead-scan-source
        scan-right
        "pkg/main.tl"
        main-source
        false
        true)]
    [scan : lint_driver_core.SelfhostLintDeadScan
      (lint_driver_core.selfhost-lint-package-dead-add-kind-roots
        scan-main
        CompilerPkgKindBin)]
    (lint_driver_core.selfhost-lint-dead-mark-roots-from
      scan.decls
      scan.roots
      0)))

(define (selfhost-lint-package-dead-moduleless-import-fixture-decls) : lint_driver_core.SelfhostLintDeadDecls
  (let
    [left-source : String (selfhost-lint-package-dead-moduleless-left-source)]
    [right-source : String (selfhost-lint-package-dead-moduleless-right-source)]
    [main-source : String (selfhost-lint-package-dead-moduleless-main-source)]
    [scan-left : lint_driver_core.SelfhostLintDeadScan
      (lint_driver_core.selfhost-lint-dead-scan-source
        (lint_driver_core.SelfhostLintDeadScan
          (lint_driver_core.selfhost-lint-dead-decls-empty)
          (lint_svec.new))
        "pkg/left.tl"
        left-source
        false
        true)]
    [scan-right : lint_driver_core.SelfhostLintDeadScan
      (lint_driver_core.selfhost-lint-dead-scan-source
        scan-left
        "pkg/right.tl"
        right-source
        false
        true)]
    [scan-main : lint_driver_core.SelfhostLintDeadScan
      (lint_driver_core.selfhost-lint-dead-scan-source
        scan-right
        "pkg/main.tl"
        main-source
        false
        true)]
    [scan : lint_driver_core.SelfhostLintDeadScan
      (lint_driver_core.selfhost-lint-package-dead-add-kind-roots
        scan-main
        CompilerPkgKindBin)]
    (lint_driver_core.selfhost-lint-dead-mark-roots-from
      scan.decls
      scan.roots
      0)))

(define (selfhost-lint-package-dead-import-closure-fixture-ok?) : bool
  (let
    [root : String "target/lint_dead_root_import_closure"]
    [src-dir : String
      (compiler_load.compiler-load-join-root-path
        (owned_view.compiler-owned-shared-view root)
        "src")]
    [test-dir : String
      (compiler_load.compiler-load-join-root-path
        (owned_view.compiler-owned-shared-view src-dir)
        "tests")]
    [manifest-path : String
      (compiler_load.compiler-load-join-root-path
        (owned_view.compiler-owned-shared-view root)
        "typelisp.pkg")]
    [main-path : String
      (compiler_load.compiler-load-join-root-path
        (owned_view.compiler-owned-shared-view src-dir)
        "main.tl")]
    [core-path : String
      (compiler_load.compiler-load-join-root-path
        (owned_view.compiler-owned-shared-view src-dir)
        "core.tl")]
    [test-path : String
      (compiler_load.compiler-load-join-root-path
        (owned_view.compiler-owned-shared-view test-dir)
        "imported_smoke.tl")]
    [second-test-path : String
      (compiler_load.compiler-load-join-root-path
        (owned_view.compiler-owned-shared-view test-dir)
        "second_imported_smoke.tl")]
    (begin
      (compiler_load.compiler-load-test-mkdir
        (owned_view.compiler-owned-shared-view root))
      (compiler_load.compiler-load-test-mkdir
        (owned_view.compiler-owned-shared-view src-dir))
      (compiler_load.compiler-load-test-mkdir
        (owned_view.compiler-owned-shared-view test-dir))
      (selfhost-lint-write-text
        (owned_view.compiler-owned-shared-view manifest-path)
        "(package
  (name \"lint-dead-root-import-closure\")
  (version \"1\")
  (kind \"bin\"))")
      (selfhost-lint-write-text
        main-path
        "(import core)
(define (main) : i64
  (core.core-entry))")
      (selfhost-lint-write-text
        (owned_view.compiler-owned-shared-view core-path)
        "(define (core-entry) : i64 7)
(define (core-test-helper) : i64 42)
(define (core-second-test-helper) : i64 43)
(define (core-unused) : i64 13)")
      (selfhost-lint-write-text
        test-path
        "(import core)
(define (main) : i64
  (core.core-test-helper))")
      (selfhost-lint-write-text
        second-test-path
        "(import core)
(define (main) : i64
  (core.core-second-test-helper))")
      (match (package_source_core.package-source-discover-for
        "lint"
        manifest-path
        true)
        [(package_source_core.ResultPackageSourceSet.Err _) false]
        [(package_source_core.ResultPackageSourceSet.Ok source-set)
          (match (lint_driver_core.selfhost-lint-package-dead-sources
            (owned_view.compiler-owned-shared-view source-set)
            (lint_svec.new))
            [(lint_driver_core.ResultSelfhostLintDeadSources.Err _) false]
            [(lint_driver_core.ResultSelfhostLintDeadSources.Ok dead-source-set)
              (let
                [roots : lint_svec.Vec
                  (lint_driver_core.selfhost-lint-package-import-roots
                    (owned_view.compiler-owned-shared-view source-set)
                    (lint_svec.new))]
                [dead-decls : lint_driver_core.SelfhostLintDeadDecls
                  (lint_driver_core.selfhost-lint-package-dead-code
                    dead-source-set
                    (owned_view.compiler-owned-shared-view roots)
                    source-set.manifest.kind)]
                [core-count : i64
                  (lint_driver_core.selfhost-lint-package-dead-count-for-source
                    (compiler_load.compiler-load-normalize-path
                      (owned_view.compiler-owned-shared-view core-path))
                    (byte_buf.to-string (io.read-file core-path))
                    dead-decls)]
                (and
                  (lint_svec.contains?
                    (& roots)
                    (compiler_load.compiler-load-normalize-path src-dir))
                  (= core-count 1)))])]))))

(define (selfhost-lint-package-dead-code-self-test) : i64
  (let
    [source-a : String (selfhost-lint-package-dead-source-a)]
    [source-b : String (selfhost-lint-package-dead-source-b)]
    [cfg-source : String (selfhost-lint-package-dead-cfg-source)]
    [bin-decls : lint_driver_core.SelfhostLintDeadDecls
      (selfhost-lint-package-dead-code-fixture-decls
        (owned_view.compiler-owned-shared-view source-a)
        (owned_view.compiler-owned-shared-view source-b)
        CompilerPkgKindBin)]
    [lib-decls : lint_driver_core.SelfhostLintDeadDecls
      (selfhost-lint-package-dead-code-fixture-decls
        (owned_view.compiler-owned-shared-view source-a)
        (owned_view.compiler-owned-shared-view source-b)
        CompilerPkgKindLib)]
    [bin-count-a : i64
      (lint_driver_core.selfhost-lint-package-dead-count-for-source
        "pkg/a.tl"
        (owned_view.compiler-owned-shared-view source-a)
        (owned_view.compiler-owned-shared-view bin-decls))]
    [bin-count-b : i64
      (lint_driver_core.selfhost-lint-package-dead-count-for-source
        "pkg/b.tl"
        (owned_view.compiler-owned-shared-view source-b)
        bin-decls)]
    [lib-count-a : i64
      (lint_driver_core.selfhost-lint-package-dead-count-for-source
        "pkg/a.tl"
        (owned_view.compiler-owned-shared-view source-a)
        (owned_view.compiler-owned-shared-view lib-decls))]
    [lib-count-b : i64
      (lint_driver_core.selfhost-lint-package-dead-count-for-source
        "pkg/b.tl"
        source-b
        lib-decls)]
    [test-root-decls : lint_driver_core.SelfhostLintDeadDecls
      (selfhost-lint-package-dead-code-test-root-fixture-decls)]
    [test-root-count : i64
      (lint_driver_core.selfhost-lint-package-dead-count-for-source
        "pkg/src/main.tl"
        (selfhost-lint-package-dead-entry-source)
        test-root-decls)]
    [manifest-root-source : String
      (selfhost-lint-package-dead-manifest-root-source)]
    [manifest-root-decls : lint_driver_core.SelfhostLintDeadDecls
      (selfhost-lint-package-dead-code-manifest-root-fixture-decls)]
    [manifest-root-count : i64
      (lint_driver_core.selfhost-lint-package-dead-count-for-source
        (compiler_load.compiler-load-normalize-path
          (compiler_load.compiler-load-join-root-path
            "pkg"
            "src/manifest_api.tl"))
        manifest-root-source
        manifest-root-decls)]
    [explicit-root-source : String
      (selfhost-lint-package-dead-explicit-root-source)]
    [explicit-root-decls : lint_driver_core.SelfhostLintDeadDecls
      (selfhost-lint-package-dead-code-explicit-root-fixture-decls)]
    [explicit-root-count : i64
      (lint_driver_core.selfhost-lint-package-dead-count-for-source
        "pkg/explicit_api.tl"
        explicit-root-source
        explicit-root-decls)]
    [cfg-bin-decls : lint_driver_core.SelfhostLintDeadDecls
      (selfhost-lint-package-dead-code-cfg-fixture-decls)]
    [cfg-bin-count : i64
      (lint_driver_core.selfhost-lint-package-dead-count-for-source
        "pkg/cfg.tl"
        cfg-source
        (owned_view.compiler-owned-shared-view cfg-bin-decls))]
    [ordinary-mode-index : i64
      (lint_driver_core.selfhost-lint-dead-decls-index-of
        (owned_view.compiler-owned-shared-view cfg-bin-decls)
        "ordinary-mode-helper")]
    [qualified-import-decls : lint_driver_core.SelfhostLintDeadDecls
      (selfhost-lint-package-dead-qualified-import-fixture-decls)]
    [qualified-left-count : i64
      (lint_driver_core.selfhost-lint-package-dead-count-for-source
        "pkg/left.tl"
        (selfhost-lint-package-dead-qualified-left-source)
        (owned_view.compiler-owned-shared-view qualified-import-decls))]
    [qualified-right-count : i64
      (lint_driver_core.selfhost-lint-package-dead-count-for-source
        "pkg/right.tl"
        (selfhost-lint-package-dead-qualified-right-source)
        qualified-import-decls)]
    [moduleless-import-decls : lint_driver_core.SelfhostLintDeadDecls
      (selfhost-lint-package-dead-moduleless-import-fixture-decls)]
    [moduleless-left-count : i64
      (lint_driver_core.selfhost-lint-package-dead-count-for-source
        "pkg/left.tl"
        (selfhost-lint-package-dead-moduleless-left-source)
        (owned_view.compiler-owned-shared-view moduleless-import-decls))]
    [moduleless-right-count : i64
      (lint_driver_core.selfhost-lint-package-dead-count-for-source
        "pkg/right.tl"
        (selfhost-lint-package-dead-moduleless-right-source)
        moduleless-import-decls)]
    [finding : lint_core.LintFinding
      (lint_core.lint-dead-code-finding "unused" (lint_core.lint-no-span))]
    [finding-message : String finding.message]
    [dead-suggestion : String (lint_core.lint-rule-dead-code-suggestion)]
    [private-needle : String "private"]
    [export-needle : String "export"]
    (cond
      [(not (= bin-count-a 1)) 50]
      [(not (= bin-count-b 0)) 51]
      [(not (= lib-count-a 0)) 52]
      [(not (= lib-count-b 0)) 53]
      [(not (= test-root-count 1)) 57]
      [(not (= manifest-root-count 1)) 62]
      ;; The explicit API and its dependency stay live. The prefix-colliding
      ;; declaration and the unrelated sibling remain dead.
      [(not (= explicit-root-count 2)) 63]
      ;; Supported scratch, embedded-TLCI, and profile cfgs reach their live
      ;; helpers and retain one dead declaration each. The ordinary
      ;; compile-profile fallback also stays live. The inactive experimental
      ;; cfg stays absent; the unrelated ordinary bin-local declaration is
      ;; still dead.
      [(not (= cfg-bin-count 4)) 61]
      [(or
          (< ordinary-mode-index 0)
          (not
            (__tl-project-field
              (lint_driver_core.selfhost-lint-dead-decls-ref
                cfg-bin-decls
                ordinary-mode-index)
              root)))
        66]
      [(not (selfhost-lint-package-dead-import-closure-fixture-ok?)) 58]
      [(not (= qualified-left-count 1)) 59]
      [(not (= qualified-right-count 0)) 60]
      ;; Moduleless dotted imports use their path-derived default aliases.
      ;; Duplicate declaration/helper names in both imported modules remain
      ;; distinct, while each unrelated sibling remains dead.
      [(not (= moduleless-left-count 1)) 64]
      [(not (= moduleless-right-count 1)) 65]
      [(not
          (string.eq
            (lint_core.lint-rule-message (lint_core.lint-rule-dead-code-id))
            (lint_core.lint-rule-dead-code-message)))
        54]
      [(string.contains (& finding-message) (& private-needle)) 55]
      [(string.contains (& dead-suggestion) (& export-needle)) 56]
      [else 42])))

(define (selfhost-lint-unused-assignment-self-test) : i64
  (let
    [rule : String (lint_core.lint-rule-unused-assignment-id)]
    (cond
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-unused-assignment-init-source)
              (owned_view.compiler-owned-shared-view rule))
            1))
        50]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-unused-assignment-set-source)
              (owned_view.compiler-owned-shared-view rule))
            1))
        51]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-used-before-overwrite-source)
              (owned_view.compiler-owned-shared-view rule))
            0))
        52]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-branch-conservative-assignment-source)
              (owned_view.compiler-owned-shared-view rule))
            0))
        53]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-underscore-assignment-source)
              (owned_view.compiler-owned-shared-view rule))
            0))
        54]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-suppressed-unused-assignment-source)
              (owned_view.compiler-owned-shared-view rule))
            0))
        55]
      [(not
          (string.eq
            (lint_core.lint-rule-message rule)
            (lint_core.lint-rule-unused-assignment-message)))
        56]
      [else 42])))

(define (selfhost-lint-single-element-array-cell-self-test) : i64
  (let
    [rule : String (lint_core.lint-rule-single-element-array-cell-id)]
    (cond
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-single-element-array-fixed-source)
              (owned_view.compiler-owned-shared-view rule))
            1))
        60]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-single-element-array-param-source)
              (owned_view.compiler-owned-shared-view rule))
            1))
        61]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-single-element-array-dynamic-source)
              (owned_view.compiler-owned-shared-view rule))
            1))
        62]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-single-element-array-dotted-source)
              (owned_view.compiler-owned-shared-view rule))
            1))
        63]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-single-element-array-nonzero-source)
              (owned_view.compiler-owned-shared-view rule))
            0))
        64]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-single-element-array-dynamic-index-source)
              (owned_view.compiler-owned-shared-view rule))
            0))
        65]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-single-element-array-escape-source)
              (owned_view.compiler-owned-shared-view rule))
            0))
        66]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-single-element-array-aggregate-source)
              (owned_view.compiler-owned-shared-view rule))
            0))
        67]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-single-element-array-suppressed-source)
              (owned_view.compiler-owned-shared-view rule))
            0))
        68]
      [(not
          (string.eq
            (lint_core.lint-rule-message rule)
            (lint_core.lint-rule-single-element-array-cell-message)))
        69]
      [else 42])))

(define (selfhost-lint-dynamic-array-literal-self-test) : i64
  (let
    [rule : String (lint_core.lint-rule-prefer-dynamic-array-literal-id)]
    (cond
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-dynamic-array-literal-dotted-source)
              (owned_view.compiler-owned-shared-view rule))
            1))
        140]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-dynamic-array-literal-private-source)
              (owned_view.compiler-owned-shared-view rule))
            1))
        141]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-dynamic-array-literal-return-source)
              (owned_view.compiler-owned-shared-view rule))
            1))
        152]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-dynamic-array-literal-assignment-source)
              (owned_view.compiler-owned-shared-view rule))
            1))
        153]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-dynamic-array-literal-ambiguous-two-var-source)
              (owned_view.compiler-owned-shared-view rule))
            0))
        149]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-dynamic-array-literal-read-before-complete-source)
              (owned_view.compiler-owned-shared-view rule))
            0))
        142]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-dynamic-array-literal-computed-index-source)
              (owned_view.compiler-owned-shared-view rule))
            0))
        143]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-dynamic-array-literal-duplicate-index-source)
              (owned_view.compiler-owned-shared-view rule))
            0))
        150]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-dynamic-array-literal-gapped-index-source)
              (owned_view.compiler-owned-shared-view rule))
            0))
        151]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-dynamic-array-literal-partial-source)
              (owned_view.compiler-owned-shared-view rule))
            0))
        144]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-dynamic-array-literal-escape-source)
              (owned_view.compiler-owned-shared-view rule))
            0))
        145]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-dynamic-array-literal-suppressed-source)
              (owned_view.compiler-owned-shared-view rule))
            0))
        146]
      [(not
          (string.eq
            (lint_core.lint-rule-message
              (owned_view.compiler-owned-shared-view rule))
            (lint_core.lint-rule-prefer-dynamic-array-literal-message)))
        147]
      [(not
          (string.eq
            (lint_core.lint-rule-suggestion rule)
            (lint_core.lint-rule-prefer-dynamic-array-literal-suggestion)))
        148]
      [else 42])))

;; Compatibility helper retained for the nested-if-ladder metadata shape.
(define (selfhost-lint-reported-finding-ok?
  [findings : lint_core.LintFindings]
  [depth : i64]
  [message : String]) : bool
  (match (lint_core.lint-findings-get
    (owned_view.compiler-owned-shared-view findings)
    0)
    [(lint_core.LintMaybeFinding.Some finding)
      (let
        [fspan : ast.AstSourceSpan finding.span]
        (and
          (= finding.depth depth)
          (> (ast.ast-source-span-start-line fspan) 0)
          (string.eq finding.rule-id (lint_core.lint-rule-nested-if-ladder-id))
          (string.eq finding.message message)))]
    [(lint_core.LintMaybeFinding.No) false]))

(define (selfhost-lint-nested-let-finding-ok?
  [findings : lint_core.LintFindings]) : bool
  (match (lint_core.lint-findings-get
    (owned_view.compiler-owned-shared-view findings)
    0)
    [(lint_core.LintMaybeFinding.Some finding)
      (let
        [fspan : ast.AstSourceSpan finding.span]
        (and
          (> (ast.ast-source-span-start-line fspan) 0)
          (string.eq finding.rule-id (lint_core.lint-rule-nested-let-id))))]
    [(lint_core.LintMaybeFinding.No) false]))

(define (selfhost-lint-return-path-finding-ok?
  [findings : lint_core.LintFindings]) : bool
  (match (lint_core.lint-findings-get
    (owned_view.compiler-owned-shared-view findings)
    0)
    [(lint_core.LintMaybeFinding.Some finding)
      (let
        [fspan : ast.AstSourceSpan finding.span]
        (and
          (= finding.depth 3)
          (> (ast.ast-source-span-start-line fspan) 0)
          (string.eq finding.rule-id (lint_core.lint-rule-return-path-chain-id))))]
    [(lint_core.LintMaybeFinding.No) false]))

(define (selfhost-lint-unit-if-finding-ok? [findings : lint_core.LintFindings]) : bool
  (match (lint_core.lint-findings-get
    (owned_view.compiler-owned-shared-view findings)
    0)
    [(lint_core.LintMaybeFinding.Some finding)
      (let
        [fspan : ast.AstSourceSpan finding.span]
        (and
          (= finding.depth 1)
          (> (ast.ast-source-span-start-line fspan) 0)
          (string.eq finding.rule-id (lint_core.lint-rule-unit-if-guard-id))))]
    [(lint_core.LintMaybeFinding.No) false]))

(define (selfhost-lint-cascading-and-or-finding-ok?
  [findings : lint_core.LintFindings]
  [message : String]) : bool
  (match (lint_core.lint-findings-get
    (owned_view.compiler-owned-shared-view findings)
    0)
    [(lint_core.LintMaybeFinding.Some finding)
      (let
        [fspan : ast.AstSourceSpan finding.span]
        (and
          (= finding.depth 3)
          (> (ast.ast-source-span-start-line fspan) 0)
          (string.eq finding.rule-id (lint_core.lint-rule-cascading-and-or-id))
          (string.eq finding.message message)))]
    [(lint_core.LintMaybeFinding.No) false]))

(define (selfhost-lint-transitional-core-macro-finding-ok?
  [findings : lint_core.LintFindings]) : bool
  (match (lint_core.lint-findings-get
    (owned_view.compiler-owned-shared-view findings)
    0)
    [(lint_core.LintMaybeFinding.Some finding)
      (and
        (=
          (lint_core.lint-findings-count
            (owned_view.compiler-owned-shared-view findings))
          5)
        (string.eq
          finding.rule-id
          (lint_core.lint-rule-transitional-core-macro-qualifier-id))
        (string.eq
          finding.message
          "transitional core macro qualifier: use when instead of core.when"))]
    [(lint_core.LintMaybeFinding.No) false]))

(define (compiler-lint-driver-self-test) : i64
  (let
    [reported : lint_core.LintFindings
      (lint_driver_core.selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-ladder-source)
        (lint_svec.new))]
    [guard-reported : lint_core.LintFindings
      (lint_driver_core.selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-guard-ladder-source)
        (lint_svec.new))]
    [return-reported : lint_core.LintFindings
      (lint_driver_core.selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-return-path-chain-source)
        (lint_svec.new))]
    [all-exit-ladder-reported : lint_core.LintFindings
      (lint_driver_core.selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-all-exit-ladder-source)
        (lint_svec.new))]
    [unit-reported : lint_core.LintFindings
      (lint_driver_core.selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-unit-if-source)
        (lint_svec.new))]
    [unit-set-reported : lint_core.LintFindings
      (lint_driver_core.selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-unit-set-source)
        (lint_svec.new))]
    [two-reported : lint_core.LintFindings
      (lint_driver_core.selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-two-findings-source)
        (lint_svec.new))]
    [cascading-and-reported : lint_core.LintFindings
      (lint_driver_core.selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-cascading-and-source)
        (lint_svec.new))]
    [cascading-or-reported : lint_core.LintFindings
      (lint_driver_core.selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-cascading-or-source)
        (lint_svec.new))]
    [cascading-core-and-reported : lint_core.LintFindings
      (lint_driver_core.selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-cascading-core-and-source)
        (lint_svec.new))]
    [transitional-core-reported : lint_core.LintFindings
      (lint_driver_core.selfhost-lint-source-with-roots
        "lint_driver_self_test.tl"
        (selfhost-lint-transitional-core-macro-source)
        (lint_svec.new))]
    (cond
      [(or
          (not
            (=
              (lint_core.lint-findings-count
                (owned_view.compiler-owned-shared-view reported))
              1))
          (not
            (selfhost-lint-reported-finding-ok?
              reported
              5
              (lint_core.lint-rule-nested-if-ladder-value-message))))
        1]
      [(or
          (not
            (=
              (lint_core.lint-findings-count
                (owned_view.compiler-owned-shared-view guard-reported))
              1))
          (not
            (selfhost-lint-reported-finding-ok?
              guard-reported
              3
              (lint_core.lint-rule-nested-if-ladder-guard-message))))
        70]
      [(not
          (=
            (lint_core.lint-findings-count
              (owned_view.compiler-owned-shared-view return-reported))
            1))
        9]
      [(not (selfhost-lint-return-path-finding-ok? return-reported)) 10]
      [(not
          (=
            (selfhost-lint-findings-rule-count
              all-exit-ladder-reported
              (lint_core.lint-rule-nested-if-ladder-id))
            0))
        41]
      [(not
          (=
            (lint_core.lint-findings-count
              (owned_view.compiler-owned-shared-view unit-reported))
            1))
        12]
      [(not (selfhost-lint-unit-if-finding-ok? unit-reported)) 13]
      [(not
          (=
            (lint_core.lint-findings-count
              (owned_view.compiler-owned-shared-view unit-set-reported))
            1))
        16]
      [(not (selfhost-lint-unit-if-finding-ok? unit-set-reported)) 17]
      [(not
          (=
            (lint_core.lint-findings-count
              (owned_view.compiler-owned-shared-view two-reported))
            2))
        18]
      [(not
          (=
            (lint_core.lint-findings-count
              (owned_view.compiler-owned-shared-view cascading-and-reported))
            1))
        20]
      [(not
          (selfhost-lint-cascading-and-or-finding-ok?
            cascading-and-reported
            "cascading and: prefer flat n-ary form (and a b c)"))
        21]
      [(not
          (=
            (lint_core.lint-findings-count
              (owned_view.compiler-owned-shared-view cascading-or-reported))
            1))
        22]
      [(not
          (selfhost-lint-cascading-and-or-finding-ok?
            cascading-or-reported
            "cascading or: prefer flat n-ary form (or a b c)"))
        23]
      [(not
          (=
            (lint_core.lint-findings-count
              (owned_view.compiler-owned-shared-view
                cascading-core-and-reported))
            1))
        24]
      [(not
          (selfhost-lint-cascading-and-or-finding-ok?
            cascading-core-and-reported
            "cascading and: prefer flat n-ary form (and a b c)"))
        25]
      [(not
          (=
            (lint_core.lint-findings-count
              (owned_view.compiler-owned-shared-view transitional-core-reported))
            5))
        37]
      [(not
          (selfhost-lint-transitional-core-macro-finding-ok?
            transitional-core-reported))
        38]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-clean-core-macro-text-source)
              (lint_core.lint-rule-transitional-core-macro-qualifier-id))
            0))
        39]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-suppressed-transitional-core-macro-source)
              (lint_core.lint-rule-transitional-core-macro-qualifier-id))
            0))
        40]
      [(not
          (=
            (selfhost-lint-source-finding-count (selfhost-lint-flat-and-source))
            0))
        26]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-mixed-and-or-source))
            0))
        27]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-suppressed-cascading-and-source))
            0))
        28]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-suppressed-return-path-chain-source))
            0))
        11]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-suppressed-unit-if-source))
            0))
        14]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-when-unless-source))
            0))
        15]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-redundant-divergence-padding-source)
              (lint_core.lint-rule-redundant-divergence-padding-id))
            4))
        29]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-redundant-divergence-padding-source))
            4))
        30]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-clean-divergence-source))
            0))
        31]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-suppressed-divergence-padding-source)
              (lint_core.lint-rule-redundant-divergence-padding-id))
            0))
        32]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-suppressed-ladder-source))
            0))
        3]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-wrong-allow-ladder-source))
            1))
        4]
      [(not
          (=
            (selfhost-lint-source-finding-count (selfhost-lint-clean-source))
            0))
        5]
      [(not
          (selfhost-lint-nested-let-finding-ok?
            (lint_driver_core.selfhost-lint-source-with-roots
              "lint_driver_self_test.tl"
              (selfhost-lint-nested-let-source)
              (lint_svec.new))))
        9]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-shadowing-nested-let-source))
            0))
        10]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-begin-inner-let-source))
            0))
        11]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-suppressed-nested-let-source))
            0))
        12]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-single-begin-source)
              (lint_core.lint-rule-single-begin-id))
            1))
        33]
      [(not
          (=
            (selfhost-lint-source-finding-count
              (selfhost-lint-clean-begin-source))
            0))
        34]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-cfg-begin-source)
              (lint_core.lint-rule-single-begin-id))
            0))
        36]
      [(not
          (=
            (selfhost-lint-source-rule-count
              (selfhost-lint-suppressed-single-begin-source)
              (lint_core.lint-rule-single-begin-id))
            0))
        35]
      [(not (= (lint_driver_core.selfhost-lint-enforce-exit true 1) 1)) 6]
      [(not (= (lint_driver_core.selfhost-lint-enforce-exit true 0) 0)) 7]
      [(not (= (lint_driver_core.selfhost-lint-enforce-exit false 1) 0)) 8]
      [else 42])))