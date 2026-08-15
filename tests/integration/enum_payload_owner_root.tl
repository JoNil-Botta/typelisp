;; A third module imports the matcher, reproducing the use-site context shift
;; that previously made an exhaustive nested payload pattern look refutable.
(import enum_payload_owner_matcher as matcher)

(define (main) : i64
  (matcher.run))