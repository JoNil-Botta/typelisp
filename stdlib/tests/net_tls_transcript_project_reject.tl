(import stdlib.net.tls_transcript as transcript)

(define (read-hash [hash : (& hash transcript.TlsTranscriptHash)]) : i64
  (match hash.boundary
    [(ThroughServerHello) 42]
    [_ 0]))

(define (main) : i64
  0)