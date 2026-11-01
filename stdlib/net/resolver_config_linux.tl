;# Linux resolver snapshot loading. Reads two fixed paths through bounded file
;# handles, then delegates all policy and normalization to resolver_config.
;# The injectable byte source is also the hermetic adapter test boundary.
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.net.resolver_config as config)

;: Bounded byte-source result. Errors carry logical source identity, not input.
(defenum ConfigBytesResult
  (ConfigBytesOk byte_buf.ByteBuf)
  (ConfigBytesErr config.ConfigError))

;: Map a host error to a bounded numeric detail without copying its path.
(define (host-error-code [error : io.IoError]) : i64
  (match error
    [(IoNotFound _) 2]
    [(IoPermissionDenied _) 13]
    [(IoInvalidPath _) 22]
    [(IoInterrupted _) 4]
    [(IoSystemCode code _) code]
    [(IoUnsupported _) 38]
    [(IoUnknown _) 5]))

;: Construct a structured unavailable-source error.
(define (unavailable [source : config.ConfigSource] [code : i64]) : config.ConfigError
  (config.ConfigError source 0 0 (ConfigUnavailable) code))

;: Read at most 1 MiB plus one overflow-detection byte. A bounded number of
;: short reads is guaranteed because every non-EOF success consumes >=1 byte.
;: Opened handles close exactly once on every success and failure path.
;: The path argument is for injected filesystem fixtures; errors identify the
;: logical source path returned by config.source-path.
(define (read-source-path [source : config.ConfigSource] [path : (& path str)]) : ConfigBytesResult
  (match (io.file-open path (OpenRead))
    [(ErrIoFile error)
      (ConfigBytesErr (unavailable source (host-error-code error)))]
    [(OkIoFile handle)
      (let
        [out : byte_buf.ByteBuf (byte_buf.with-capacity 1048577)]
        [done : bool false]
        (while (not done)
          (match (io.file-read-chunk handle (- 1048577 (byte_buf.len (& out))))
            [(ErrIoRead error)
              (let
                [ignored : io.ResultIoUnit (io.file-close handle)]
                (match ignored
                  [(OkIoUnit) unit]
                  [(ErrIoUnit _) unit]))
              (return
                (ConfigBytesErr (unavailable source (host-error-code error))))]
            [(OkIoRead chunk)
              (let
                [count : i64 (byte_buf.len (& chunk.bytes))]
                (set!
                  out
                  (byte_buf.append-bytes
                    out
                    (byte_buf.as-bytes (& chunk.bytes))))
                (when
                  (> (byte_buf.len (& out)) 1048576)
                  (let
                    [ignored : io.ResultIoUnit (io.file-close handle)]
                    (match ignored
                      [(OkIoUnit) unit]
                      [(ErrIoUnit _) unit]))
                  (return
                    (ConfigBytesErr
                      (config.error-at source 0 1048576 (ConfigFileTooLarge)))))
                (when
                  (and (= count 0) (not chunk.eof))
                  (let
                    [ignored : io.ResultIoUnit (io.file-close handle)]
                    (match ignored
                      [(OkIoUnit) unit]
                      [(ErrIoUnit _) unit]))
                  (return (ConfigBytesErr (unavailable source 5))))
                (set! done chunk.eof))]))
        (match (io.file-close handle)
          [(ErrIoUnit error)
            (ConfigBytesErr (unavailable source (host-error-code error)))]
          [(OkIoUnit) (ConfigBytesOk out)]))]))

;: System byte source with fixed path selection, no environment/libc resolver.
(cfg
  (not windows)
  (define (system-source [source : config.ConfigSource]) : ConfigBytesResult
    (let
      [path : String (config.source-path source)]
      (read-source-path source (& path)))))

;: Build a complete replacement through an injected bounded source.
;: The core rechecks byte bounds even when an injected source violates its cap.
(define (load-with-source [read : (-> config.ConfigSource ConfigBytesResult)]) : config.ResolverConfigResult
  (match (read (ConfigHosts))
    [(ConfigBytesErr error) (ResolverConfigErr error)]
    [(ConfigBytesOk hosts)
      (match (config.validate-source
        (byte_buf.as-bytes (& hosts))
        (ConfigHosts))
        [(ConfigInvalid error) (return (ResolverConfigErr error))]
        [(ConfigValid) unit])
      (match (read (ConfigResolv))
        [(ConfigBytesErr error) (ResolverConfigErr error)]
        [(ConfigBytesOk resolv)
          (config.parse-linux
            (byte_buf.as-bytes (& hosts))
            (byte_buf.as-bytes (& resolv)))])]))

;: Linux convenience factory. No background watcher and no caller-state mutation.
(cfg
  (not windows)
  (define (load-system) : config.ResolverConfigResult
    (load-with-source system-source)))