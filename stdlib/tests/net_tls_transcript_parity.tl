;; Pure import/ABI witness for target IR parity. Framing-only messages exercise
;; transcript mechanics; full TLS body policy and the RFC corpus live in the
;; API fixture. Avoid test/assertion I/O, which intentionally differs by host.
(import stdlib.byte_buf)
(import stdlib.crypto_sha256 as sha)
(import stdlib.net.tls_wire as wire)
(import stdlib.net.tls_transcript as transcript)

(define (absorb
  [state : (&mut state transcript.TlsTranscript)]
  [frame : (& frame bytes)]
  [retry : bool]) : bool
  (let
    [reader : wire.TlsHandshakeReader
      (wire.handshake-reader-new (wire.default-limits))]
    (match (wire.handshake-reader-feed! (&mut reader) frame)
      [(TlsWireErr _) (return false)]
      [(TlsWireOk) unit])
    (match (wire.handshake-reader-next! (&mut reader))
      [(TlsHandshakeReady _ _) unit]
      [_ (return false)])
    (match (if retry
      (transcript.hello-retry! state (& reader))
      (transcript.absorb! state (& reader)))
      [(TlsTranscriptOk) true]
      [_ false])))

(define (tag-valid?
  [state : (& state transcript.TlsTranscript)]
  [tag : transcript.TlsTranscriptBoundary]) : bool
  (match (transcript.snapshot-boundary state tag)
    [(TlsTranscriptHashOk value)
      (match (transcript.boundary-digest value tag)
        [(TlsTranscriptDigestOk digest)
          (match (transcript.snapshot state)
            [(TlsTranscriptDigestOk expected)
              (sha.digest-eq? (& digest) (& expected))]
            [_ false])]
        [_ false])]
    [_ false]))

(define (main) : i64
  (let
    [state : transcript.TlsTranscript
      (match (transcript.new (transcript.default-limits))
        [(TlsTranscriptNewOk value) value]
        [_ (return 1)])]
    [empty : byte_buf.ByteBuf (byte_buf.new)]
    [ch : byte_buf.ByteBuf
      (wire.encode-handshake (byte_buf.new) 1 (byte_buf.as-bytes (& empty)))]
    [random : byte_buf.ByteBuf (wire.hello-retry-request-random)]
    [body : byte_buf.ByteBuf (wire.push-be (byte_buf.with-capacity 34) 771 2)]
    [_filled : unit
      (set! body (byte_buf.append-bytes body (byte_buf.as-bytes (& random))))]
    [hrr : byte_buf.ByteBuf
      (wire.encode-handshake (byte_buf.new) 2 (byte_buf.as-bytes (& body)))]
    (when
      (not (absorb (&mut state) (byte_buf.as-bytes (& ch)) false))
      (return 2))
    (when
      (not (tag-valid? (& state) (transcript.ThroughClientHello)))
      (return 3))
    (when
      (not (absorb (&mut state) (byte_buf.as-bytes (& hrr)) true))
      (return 4))
    (when (tag-valid? (& state) (transcript.ThroughServerHello)) (return 5))
    (when (!= state.hash.byte-length (cast 74 : u64)) (return 6))
    (when
      (not (absorb (&mut state) (byte_buf.as-bytes (& ch)) false))
      (return 7))
    (let
      [kinds : (Array i64 4) (array 2 11 15 20)]
      [index : i64 0]
      (while (< index 4)
        (let
          [frame : byte_buf.ByteBuf
            (wire.encode-handshake
              (byte_buf.new)
              (array-ref kinds index)
              (byte_buf.as-bytes (& empty)))]
          (when
            (not (absorb (&mut state) (byte_buf.as-bytes (& frame)) false))
            (return 8))
          (let
            [tag : transcript.TlsTranscriptBoundary
              (match index
                [0 (transcript.ThroughServerHello)]
                [1 (transcript.BeforeCertificateVerify)]
                [2 (transcript.BeforeServerFinished)]
                [_ (transcript.ThroughServerFinished)])]
            (when (not (tag-valid? (& state) tag)) (return 9))))
        (set! index (+ index 1))))
    (when
      (not (tag-valid? (& state) (transcript.BeforeClientFinished)))
      (return 10))
    (when
      (not (tag-valid? (& state) (transcript.ThroughClientFinished)))
      (return 11))
    (match (transcript.finalize! (&mut state))
      [(TlsTranscriptDigestOk _) unit]
      [_ (return 12)])
    (match (transcript.snapshot (& state))
      [(TlsTranscriptDigestErr (TlsTranscriptNotLive (TlsTranscriptFinalized)))
        unit]
      [_ (return 13)])
    (transcript.close! (&mut state))
    42))