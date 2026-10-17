(import stdlib.msvc)

; A tool path remains borrowed until its last use.
(define (main) : i64
  (let
    [tool : msvc.MsvcTool (msvc.MsvcTool "link" "path" "lib" "include")]
    [path : (& tool str) (msvc.tool-path tool)]
    (set! tool.path "changed")
    (string-length path)))