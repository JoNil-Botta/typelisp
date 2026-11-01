;# Bounded RFC 7468 CERTIFICATE envelopes over borrowed bytes.
;#
;# Boundaries are exact, case-sensitive CERTIFICATE lines, with optional ASCII
;# whitespace at either edge. CR, LF and CRLF are accepted. Payload whitespace
;# is SP/HT/VT/FF/CR/LF only; all other bytes go unchanged to stdlib.base64.
;# Explanatory lines outside blocks are ignored; a line beginning with five
;# hyphens must be a valid boundary. Nested, unmatched, other-label and
;# unterminated blocks fail. At least one nonempty block is required.
;#
;# Limits are checked before payload or decoded storage is allocated. Failures
;# return no blocks and use original PEM byte offsets, including base64 errors.
;#
;# ```typelisp
;# (import stdlib.pem)
;# (import stdlib.byte_buf)
;# (define (main) : i64
;#   (let [input : String "-----BEGIN CERTIFICATE-----\nBQA=\n-----END CERTIFICATE-----\n"]
;#     ; Framing/base64 only: X.509 must separately validate the decoded DER.
;#     (match (pem.decode-certificates (byte_buf.str-as-bytes (& input)) (pem.default-limits))
;#       [(pem.PemOk _) 42]
;#       [(pem.PemErr _) 1])))
;# ```
(import stdlib.asn1_der as der)
(import stdlib.base64)
(import stdlib.byte_buf)
(import stdlib.vector)

;: Input bytes, per-block decoded bytes, aggregate decoded bytes and block count.
(defstruct Limits
  (max-input-bytes i64)
  (max-certificate-bytes i64)
  (max-total-bytes i64)
  (max-certificates i64))

;: Default bounded certificate-bundle budgets.
(define (default-limits) : Limits
  (Limits 16777216 1048576 8388608 128))

;: One owned decoded block and its complete source envelope range.
(defstruct Block
  (der byte_buf.ByteBuf)
  (source der.Range))

(import (vector.vector Block core) as blocks)

;: All decoded blocks or an original-source error, never partial output.
(defenum PemResult
  (PemOk blocks.Vec)
  (PemErr der.Error))

;: RFC 7468 ASCII whitespace; no locale-dependent classifications.
(define (whitespace? [code : u8]) : bool
  (or
    (= code (cast 32 : u8))
    (and (>= code (cast 9 : u8)) (<= code (cast 13 : u8)))))

;: Compare a bounded input line to an exact ASCII marker.
(define (line-equal?
  [input : (& input bytes)]
  [start : i64]
  [end : i64]
  [marker : String]) : bool
  (let
    [text : (& marker bytes) (byte_buf.str-as-bytes (& marker))]
    [index : i64 0]
    (when (!= (- end start) (byte_buf.bytes-length text)) (return false))
    (while (< index (- end start))
      (when
        (!=
          (byte_buf.bytes-ref input (+ start index))
          (byte_buf.bytes-ref text index))
        (return false))
      (set! index (+ index 1)))
    true))

;: Map a compacted base64 offset back to the original envelope payload.
(define (payload-offset
  [input : (& input bytes)]
  [start : i64]
  [end : i64]
  [compact-offset : i64]) : i64
  (let
    [position : i64 start]
    [index : i64 0]
    (while (< position end)
      (when
        (not (whitespace? (byte_buf.bytes-ref input position)))
        (when (= index compact-offset) (return position))
        (set! index (+ index 1)))
      (set! position (+ position 1)))
    end))

;: Decode certificate blocks using the one canonical shared base64 codec.
;: This layer owns framing only; X.509 callers must check complete DER parsing.
(define (decode-certificates [input : (& input bytes)] [limits : Limits]) : PemResult
  (when
    (or
      (< limits.max-input-bytes 0)
      (< limits.max-certificate-bytes 0)
      (< limits.max-total-bytes 0)
      (< limits.max-certificates 0))
    (return (PemErr (der.Error (der.InvalidLimit) 0))))
  (let
    [length : i64 (byte_buf.bytes-length input)]
    [position : i64 0]
    [inside : bool false]
    [envelope-start : i64 0]
    [payload-start : i64 0]
    [payload-count : i64 0]
    [total : i64 0]
    [out : blocks.Vec (blocks.with-capacity 0)]
    (when
      (> length limits.max-input-bytes)
      (return (PemErr (der.Error (der.LimitExceeded) 0))))
    (while (< position length)
      (let
        [line-start : i64 position]
        [line-end : i64 position]
        (while (and
          (< position length)
          (!= (byte_buf.bytes-ref input position) (cast 10 : u8))
          (!= (byte_buf.bytes-ref input position) (cast 13 : u8)))
          (set! position (+ position 1)))
        (set! line-end position)
        (when
          (< position length)
          (let
            [newline : u8 (byte_buf.bytes-ref input position)]
            (set! position (+ position 1))
            (when
              (and
                (= newline (cast 13 : u8))
                (< position length)
                (= (byte_buf.bytes-ref input position) (cast 10 : u8)))
              (set! position (+ position 1)))))
        (while (and
          (< line-start line-end)
          (whitespace? (byte_buf.bytes-ref input line-start)))
          (set! line-start (+ line-start 1)))
        (while (and
          (> line-end line-start)
          (whitespace? (byte_buf.bytes-ref input (- line-end 1))))
          (set! line-end (- line-end 1)))
        (cond
          [(line-equal? input line-start line-end "-----BEGIN CERTIFICATE-----")
            (when
              inside
              (return (PemErr (der.Error (der.InvalidEnvelope) line-start))))
            (when
              (>= (blocks.len (& out)) limits.max-certificates)
              (return (PemErr (der.Error (der.LimitExceeded) line-start))))
            (set! inside true)
            (set! envelope-start line-start)
            (set! payload-start position)
            (set! payload-count 0)]
          [(line-equal? input line-start line-end "-----END CERTIFICATE-----")
            (when
              (or (not inside) (= payload-count 0))
              (return (PemErr (der.Error (der.InvalidEnvelope) line-start))))
            (let
              [payload : byte_buf.ByteBuf
                (byte_buf.with-capacity payload-count)]
              [index : i64 payload-start]
              [cap : i64 (- limits.max-total-bytes total)]
              (when
                (< limits.max-certificate-bytes cap)
                (set! cap limits.max-certificate-bytes))
              (while (< index line-start)
                (let
                  [code : u8 (byte_buf.bytes-ref input index)]
                  (when
                    (not (whitespace? code))
                    (set! payload (byte_buf.push payload code))))
                (set! index (+ index 1)))
              (match (base64.decode (byte_buf.as-bytes (& payload)) cap)
                [(base64.Base64DecodeErr error)
                  (match error.kind
                    [(base64.Base64OutputLimitExceeded)
                      (return
                        (PemErr (der.Error (der.LimitExceeded) payload-start)))]
                    [_
                      (return
                        (PemErr
                          (der.Error
                            (der.InvalidBase64)
                            (payload-offset
                              input
                              payload-start
                              line-start
                              error.offset))))])]
                [(base64.Base64DecodeOk decoded)
                  (set! total (+ total (byte_buf.len decoded)))
                  (blocks.push!
                    out
                    (Block
                      decoded
                      (der.Range envelope-start (- position envelope-start))))]))
            (set! inside false)]
          [(and
              (>= (- line-end line-start) 5)
              (line-equal? input line-start (+ line-start 5) "-----"))
            (return (PemErr (der.Error (der.InvalidEnvelope) line-start)))]
          [inside
            (let
              [index : i64 line-start]
              (while (< index line-end)
                (when
                  (not (whitespace? (byte_buf.bytes-ref input index)))
                  (set! payload-count (+ payload-count 1))
                  (let
                    [minimum : i64 (- (* (/ payload-count 4) 3) 2)]
                    (when
                      (or
                        (> minimum limits.max-certificate-bytes)
                        (> minimum (- limits.max-total-bytes total)))
                      (return (PemErr (der.Error (der.LimitExceeded) index))))))
                (set! index (+ index 1))))]
          [else unit])))
    (if inside
      (PemErr (der.Error (der.InvalidEnvelope) length))
      (if (= (blocks.len (& out)) 0)
        (PemErr (der.Error (der.InvalidEnvelope) length))
        (PemOk out)))))