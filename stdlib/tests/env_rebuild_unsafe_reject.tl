;; Check-only: safe code cannot publish a replacement environment built in a
;; temporary arena, bypassing the persistent-arena mutation path (#7658).
(import stdlib.env)

(define (main) : i64
  (with-arena
    transient
    (env.linux-rebuild! "TYPELISP_PROOF_REWIND" "value" true))
  (if (env.var-exists? "TYPELISP_PROOF_REWIND")
    42
    1))