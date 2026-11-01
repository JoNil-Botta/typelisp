(import stdlib.crypto_sha256 as sha)
(import stdlib.net.tls_transcript as transcript)

(define (main) : i64
  (let
    [_forged : transcript.TlsTranscriptHash
      (transcript.TlsTranscriptHash
        (transcript.ThroughServerHello)
        (sha.Sha256Digest (make-array u8 32)))]
    0))
