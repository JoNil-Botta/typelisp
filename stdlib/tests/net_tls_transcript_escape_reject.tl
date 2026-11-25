(import stdlib.io)
(import stdlib.net.tls_transcript as transcript)

(define (main) : i64
  (let
    [state : transcript.TlsTranscript
      (match (transcript.new (transcript.default-limits))
        [(TlsTranscriptNewOk value) value]
        [_ (io.panic "valid transcript limits")])]
    ;; Built outside the arena: a value made inside it carries its region.
    [boundary : transcript.TlsTranscriptBoundary
      (transcript.ThroughServerHello)]
    [escaped : transcript.TlsTranscriptHashResult
      (with-arena scratch (transcript.snapshot-boundary (& state) boundary))]
    (match escaped
      [(TlsTranscriptHashOk value)
        (match (unsafe
          (transcript.boundary-digest value (transcript.ThroughServerHello)))
          [(TlsTranscriptDigestOk _) 42]
          [_ 1])]
      [_ 2])))