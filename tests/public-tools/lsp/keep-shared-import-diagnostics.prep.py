import os, pathlib
base = pathlib.Path(os.environ["FIXTURE_TMP"])
(base / "lib.tl").write_text("(define imported : i64 true)\n")
