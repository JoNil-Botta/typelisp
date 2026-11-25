;; A macro body cannot run a stdlib function that hides an unsafe block behind
;; a safe signature (`update!`): hydrated from prebuilt stdlib.tli it lacks the
;; PURE certificate, and the call is rejected exactly as with
;; --no-prebuilt-stdlib.
(import stdlib.byte_buf as buf)
(import stdlib.crypto_sha256 as sha)

(defmacro (digest-probe) : Expr
  (let
    [state : sha.Sha256State (sha.new)]
    (match (sha.update! (&mut state) (buf.str-as-bytes "abc"))
      [_ (expr-int 0)])))

(define (main) : i64
  (digest-probe))