;; host_plan.tl - Shared private host-action plan emit helpers (#622).
;;
;; This mirrors `src/host_action.rs`'s private `typelisp-host-plan v1` grammar.
;; The boundary is deliberately not shell-tokenized: paths and runtime args are
;; emitted as netstrings so spaces, colons, and newlines round-trip exactly.
(import stdlib.env as env_mod)

(import stdlib.string as string_mod)

(import stdlib.str_cat)

(define (host-plan-header) : String
  "typelisp-host-plan v1\n")

(define (host-plan-word-line [name : String] [value : String]) : String
  (str_cat.str-cat name " " value "\n"))

(define (host-plan-netstring [value : String]) : String
  (str_cat.str-cat (string_mod.int->string (string-length value)) ":" value))

(define (host-plan-netline [name : String] [value : String]) : String
  (str_cat.str-cat name " " (host-plan-netstring value) "\n"))

(define (host-plan-flag? [value : String]) : bool
  (and (> (string-length value) 0) (= (string-ref value 0) #-')))

(define (host-plan-target-valid? [value : String]) : bool
  (or
    (string_mod.string-eq value "linux-x86_64")
    (string_mod.string-eq value "linux_x86_64")
    (string_mod.string-eq value "windows-x86_64")
    (string_mod.string-eq value "windows_x86_64")))

(define (host-plan-default-target) : String
  (if (string_mod.string-eq (env_mod.env-path-separator) ";")
    "windows-x86_64"
    "linux-x86_64"))

(define (host-plan-backend-mode-valid? [value : String]) : bool
  (or
    (string_mod.string-eq value "scalar")
    (string_mod.string-eq value "avx2")
    (string_mod.string-eq value "avx512")))

(define (host-plan-opt-level-valid? [value : String]) : bool
  (or
    (string_mod.string-eq value "0")
    (string_mod.string-eq value "1")
    (string_mod.string-eq value "2")))