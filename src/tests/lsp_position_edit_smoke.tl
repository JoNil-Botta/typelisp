;; lsp_position_edit_smoke.tl - Smoke tests for position-based LSP edit helpers.
;;
;; Follows the same pattern as lsp_frame_smoke.tl: tests pure helper functions
;; directly, checking their return values. Does NOT test JSON-RPC handlers
;; (those write to stdout and are harder to verify in a self-hosted test).
(import "../lsp_frame_core.tl")

;; --------------------------------------------------------------------------
;; lsp-find-form-at-offset / lsp-find-form-end-at-offset
;; --------------------------------------------------------------------------
(define (lsp-find-form-at-offset-ok?) : bool
  (let
    [text : String "(define (foo) : i64 1)\n(define (bar) : i64 2)"]
    [foo-start : i64 (lsp-find-form-at-offset text 5)]
    [bar-start : i64 (lsp-find-form-at-offset text 28)]
    (and
      (= foo-start 0)
      (= bar-start 23)
      (string-eq (substring text foo-start 22) "(define (foo) : i64 1)")
      (string-eq (substring text bar-start 22) "(define (bar) : i64 2)"))))

(define (lsp-find-form-end-at-offset-ok?) : bool
  (= (lsp-find-form-end-at-offset "(define (foo) : i64 1)" 0) 22))

;; --------------------------------------------------------------------------
;; lsp-find-outer-form-start
;; --------------------------------------------------------------------------
(define (lsp-find-outer-form-start-ok?) : bool
  (let
    [text : String "(define (foo (x i64)) : i64 (+ x 1))"]
    [inner-start : i64 (lsp-find-form-at-offset text 15)]
    ; on "x i64"
    (and
      (= (lsp-find-outer-form-start text inner-start 0) inner-start)
      (= (lsp-find-outer-form-start text inner-start 1) 8)
      ; "(foo (x i64))"
      (= (lsp-find-outer-form-start text inner-start 2) 0))))

; "(define ...)"
;; --------------------------------------------------------------------------
;; lsp-read-form-at-position
;; --------------------------------------------------------------------------
(define (lsp-read-form-inner-ok?) : bool
  (let
    [text : String "(define (foo) : i64 (+ 1 2))"]
    [form : String (lsp-read-form-at-position text 0 24 0)]
    ; cursor on "(+ 1 2)"
    (string-eq form "(+ 1 2)")))

(define (lsp-read-form-outer-ok?) : bool
  (let
    [text : String "(define (foo) : i64 (+ 1 2))"]
    [form : String (lsp-read-form-at-position text 0 24 1)]
    ; outer=1
    (string-eq form "(define (foo) : i64 (+ 1 2))")))

(define (lsp-read-form-missing-ok?) : bool
  (string-eq (lsp-read-form-at-position "   " 0 1 0) ""))

;; --------------------------------------------------------------------------
;; lsp-is-whitespace
;; --------------------------------------------------------------------------
(define (lsp-is-whitespace-ok?) : bool
  (and
    (lsp-is-whitespace (string-ref " " 0))
    (lsp-is-whitespace (string-ref "\t" 0))
    (lsp-is-whitespace (string-ref "\n" 0))
    (lsp-is-whitespace (string-ref "\r" 0))
    (not (lsp-is-whitespace (string-ref "a" 0)))))

;; --------------------------------------------------------------------------
;; lsp-extract-define-name
;; --------------------------------------------------------------------------
(define (lsp-extract-define-name-fun-ok?) : bool
  (string-eq (lsp-extract-define-name "(define (foo (x i64)) : i64 1)") "foo"))

(define (lsp-extract-define-name-var-ok?) : bool
  (string-eq (lsp-extract-define-name "(define answer : i64 42)") "answer"))

(define (lsp-extract-define-name-nondefine-ok?) : bool
  (string-eq (lsp-extract-define-name "(let [x : i64 1] x)") ""))

;; --------------------------------------------------------------------------
;; lsp-find-and-extract-name
;; --------------------------------------------------------------------------
(define (lsp-find-and-extract-name-ok?) : bool
  (let
    [text : String "(define (foo) : i64 1)\n(define (bar) : i64 2)"]
    (and
      (string-eq (lsp-find-and-extract-name text 0 5) "foo")
      (string-eq (lsp-find-and-extract-name text 1 5) "bar"))))

;; --------------------------------------------------------------------------
;; main
;; --------------------------------------------------------------------------
(define (main) : i64
  (begin
    (unless (lsp-find-form-at-offset-ok?) (return 1))
    (unless (lsp-find-form-end-at-offset-ok?) (return 2))
    (unless (lsp-find-outer-form-start-ok?) (return 3))
    (unless (lsp-read-form-inner-ok?) (return 4))
    (unless (lsp-read-form-outer-ok?) (return 5))
    (unless (lsp-read-form-missing-ok?) (return 6))
    (unless (lsp-is-whitespace-ok?) (return 7))
    (unless (lsp-extract-define-name-fun-ok?) (return 8))
    (unless (lsp-extract-define-name-var-ok?) (return 9))
    (unless (lsp-extract-define-name-nondefine-ok?) (return 10))
    (unless (lsp-find-and-extract-name-ok?) (return 11))
    42))