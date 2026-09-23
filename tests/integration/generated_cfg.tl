(import stdlib.io)

;; Constructed cfg forms use this compilation's predicates for both Decls and
;; Module output. Native manifests exercise both target presets; driver-state
;; smoke coverage alternates enabled and disabled custom cfg jobs.
(defmacro (emit-nested) : Decls
  '(define (nested-answer) : i64
    42))

(defmacro (emit-configured) : Decls
  (let
    [cfg-head : Expr (expr-var "cfg")]
    [flag : Expr (expr-var (string-append "generated-cfg-" "feature"))]
    `(begin
      (,cfg-head
        ,flag
        (define (enabled-answer) : i64
          42))
      (,cfg-head
        (not ,flag)
        (define (disabled-answer) : i64
          42))
      (,cfg-head (any linux windows) (emit-nested))
      (,cfg-head (all linux windows) (import nonexistent_cfg_dependency)))))

(emit-configured)

(defmacro (configured-module) : Module
  (let
    [cfg-head : Expr (expr-var "cfg")]
    [linux : Expr (expr-var (string-append "lin" "ux"))]
    [windows : Expr (expr-var (string-append "win" "dows"))]
    `(begin
      (module generated.cfg_fixture)
      (,cfg-head
        ,linux
        (define (platform-answer) : i64
          42))
      (,cfg-head
        ,windows
        (define (platform-answer) : i64
          42))
      (,cfg-head
        (not (any linux windows))
        (import nonexistent_cfg_module_dependency)))))

(import (configured-module) as configured)

(define (main) : i64
  (if (and
    (= (cfg generated-cfg-feature (enabled-answer) (disabled-answer)) 42)
    (= (nested-answer) 42)
    (= (configured.platform-answer) 42))
    42
    1))

(test
  generated-cfg-test-harness
  (unless
    (and
      (= (cfg generated-cfg-feature (enabled-answer) (disabled-answer)) 42)
      (= (nested-answer) 42)
      (= (configured.platform-answer) 42))
    (io.panic "generated cfg test harness selected the wrong declarations")))