(import stdlib.net.tls_transcript as transcript)

(define (main) : i64
  (let
    [state : transcript.TlsTranscript
      (match (transcript.new (transcript.default-limits))
        [(TlsTranscriptNewOk value) value]
        [_ (init : transcript.TlsTranscript)])]
    [escaped : transcript.TlsTranscriptHashResult
      (with-arena
        scratch
        (transcript.snapshot-boundary
          (& state)
          (clone (transcript.ThroughServerHello))))]
    (match escaped
      [(TlsTranscriptHashOk value)
        (match (transcript.boundary-digest
          value
          (transcript.ThroughServerHello))
          [(TlsTranscriptDigestOk _) 42]
          [_ 1])]
      [_ 2])))