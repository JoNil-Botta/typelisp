;; host_plan.tl - Shared private host-action plan emit helpers (#622).
;;
;; This mirrors `src/host_action.rs`'s private `typelisp-host-plan v1` grammar.
;; The boundary is deliberately not shell-tokenized: paths and runtime args are
;; emitted as netstrings so spaces, colons, and newlines round-trip exactly.
(define (host-plan-cat3 [a : String] [b : String] [c : String]) : String
  (string-append a (string-append b c)))

(define (host-plan-header) : String
  "typelisp-host-plan v1\n")

(define (host-plan-word-line [name : String] [value : String]) : String
  (host-plan-cat3 name " " (string-append value "\n")))

(define (host-plan-netstring [value : String]) : String
  (host-plan-cat3 (int->string (string-length value)) ":" value))

(define (host-plan-netline [name : String] [value : String]) : String
  (host-plan-cat3 name " " (string-append (host-plan-netstring value) "\n")))

(define (host-plan-flag? [value : String]) : bool
  (and (> (string-length value) 0) (= (string-ref value 0) #-')))

(define (host-plan-target-valid? [value : String]) : bool
  (or
    (string-eq value "linux-x86_64")
    (or
      (string-eq value "linux_x86_64")
      (or (string-eq value "windows-x86_64") (string-eq value "windows_x86_64")))))

(define (host-plan-default-target) : String
  (if (string-eq (env-path-separator) ";")
    "windows-x86_64"
    "linux-x86_64"))

(define (host-plan-backend-mode-valid? [value : String]) : bool
  (or
    (string-eq value "scalar")
    (or (string-eq value "avx2") (string-eq value "avx512"))))

(define (host-plan-opt-level-valid? [value : String]) : bool
  (or
    (string-eq value "0")
    (or (string-eq value "1") (or (string-eq value "2") (string-eq value "3")))))