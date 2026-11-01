;# Bounded target-neutral ASCII DNS names shared by resolver snapshots and policy.
;# Values are immutable by API, like the other stdlib owned value collections.
;# A final dot is retained as identity separately from lowercase canonical text.
(import stdlib.byte_buf)
(import stdlib.string)

;: Validated lowercase LDH labels, excluding the optional final dot.
(defstruct DnsName
  (canonical String)
  (rooted bool)
  (labels i64))

;: Stable name validation failures, without retaining the input.
(defenum DnsNameErrorKind
  (DnsNameEmpty)
  (DnsNameTooLong)
  (DnsNameEmptyLabel)
  (DnsNameLabelTooLong)
  (DnsNameInvalidByte)
  (DnsNameHyphenBoundary)
  (DnsNameTooManyLabels))

;: Zero-based byte offset in the original input.
(defstruct DnsNameError
  (kind DnsNameErrorKind)
  (offset i64))

;: Checked name construction result.
(defenum DnsNameResult
  (DnsNameOk DnsName)
  (DnsNameErr DnsNameError))

;: Lowercase canonical text, without a final dot.
(define (text [name : (& name DnsName)]) : (& name str)
  (& name.canonical))

;: Whether the caller explicitly supplied a final dot.
(define (rooted? [name : (& name DnsName)]) : bool
  name.rooted)

;: Expanded DNS wire size including label lengths and the root octet.
(define (wire-length [name : (& name DnsName)]) : i64
  (+ (string.string-length (& name.canonical)) 2))

;: Number of checked labels.
(define (label-count [name : (& name DnsName)]) : i64
  name.labels)

;: ASCII-only lowercase conversion.
(define (ascii-lower [value : u8]) : u8
  (if (and (>= value 65) (<= value 90))
    (+ value 32)
    value))

;: Parse at most 254 text bytes with 63-byte labels and a 255-byte wire limit.
;: Offsets count bytes, including when the input contains invalid UTF-8.
(define (parse-bytes [input : (& input bytes)]) : DnsNameResult
  (let
    [length : i64 (byte_buf.bytes-length input)]
    (when (= length 0) (return (DnsNameErr (DnsNameError (DnsNameEmpty) 0))))
    (when
      (> length 254)
      (return (DnsNameErr (DnsNameError (DnsNameTooLong) 254))))
    (let
      [rooted : bool (= (byte_buf.bytes-ref input (- length 1)) 46)]
      [end : i64
        (if rooted
          (- length 1)
          length)]
      [label-start : i64 0]
      [labels : i64 1]
      [cursor : i64 0]
      (when
        (> end 253)
        (return (DnsNameErr (DnsNameError (DnsNameTooLong) 253))))
      (when
        (= end 0)
        (return (DnsNameErr (DnsNameError (DnsNameEmptyLabel) 0))))
      (while (< cursor end)
        (let
          [value : u8 (byte_buf.bytes-ref input cursor)]
          (cond
            [(= value 46)
              (when
                (= cursor label-start)
                (return (DnsNameErr (DnsNameError (DnsNameEmptyLabel) cursor))))
              (when
                (= (byte_buf.bytes-ref input (- cursor 1)) 45)
                (return
                  (DnsNameErr
                    (DnsNameError (DnsNameHyphenBoundary) (- cursor 1)))))
              (set! labels (+ labels 1))
              (when
                (> labels 127)
                (return
                  (DnsNameErr (DnsNameError (DnsNameTooManyLabels) cursor))))
              (set! label-start (+ cursor 1))]
            [else
              (let
                [lower : u8 (ascii-lower value)]
                (when
                  (not
                    (or
                      (and (>= lower 97) (<= lower 122))
                      (and (>= value 48) (<= value 57))
                      (= value 45)))
                  (return
                    (DnsNameErr (DnsNameError (DnsNameInvalidByte) cursor))))
                (when
                  (and (= cursor label-start) (= value 45))
                  (return
                    (DnsNameErr (DnsNameError (DnsNameHyphenBoundary) cursor))))
                (when
                  (>= (- cursor label-start) 63)
                  (return
                    (DnsNameErr (DnsNameError (DnsNameLabelTooLong) cursor)))))]))
        (set! cursor (+ cursor 1)))
      (when
        (= label-start end)
        (return (DnsNameErr (DnsNameError (DnsNameEmptyLabel) end))))
      (when
        (= (byte_buf.bytes-ref input (- end 1)) 45)
        (return (DnsNameErr (DnsNameError (DnsNameHyphenBoundary) (- end 1)))))
      (let
        [out : byte_buf.ByteBuf (byte_buf.with-capacity end)]
        (set! cursor 0)
        (while (< cursor end)
          (set!
            out
            (byte_buf.push out (ascii-lower (byte_buf.bytes-ref input cursor))))
          (set! cursor (+ cursor 1)))
        (DnsNameOk (DnsName (byte_buf.to-string out) rooted labels))))))

;: Parse borrowed text without consulting files, environment, or DNS.
(define (parse [input : (& input str)]) : DnsNameResult
  (parse-bytes (byte_buf.str-as-bytes input)))

;: Exact normalized identity includes explicit rootedness.
(define (equal? [left : (& left DnsName)] [right : (& right DnsName)]) : bool
  (and (= left.rooted right.rooted) (string.eq (text left) (text right))))

;: Localhost and every dot-delimited subname are reserved loopback policy.
;: This predicate does not consult or modify hosts data.
(define (localhost? [name : (& name DnsName)]) : bool
  (let
    [canonical : (& name str) (text name)]
    [length : i64 (string.string-length canonical)]
    (or
      (string.eq canonical "localhost")
      (and
        (> length 10)
        (string.eq
          (string.substring-view canonical (- length 10) 10)
          ".localhost")))))