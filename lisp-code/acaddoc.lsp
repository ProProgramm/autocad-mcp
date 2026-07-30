;;; acaddoc.lsp — auto-load the MCP dispatcher into every document namespace.
;;;
;;; WHY THIS FILE EXISTS
;;;   AutoLISP definitions live in a per-document namespace. Loading
;;;   mcp_dispatch.lsp by hand (APPLOAD) defines (c:mcp-dispatch) only in the
;;;   drawing that was open at the time. Open a second drawing — including via
;;;   the server's own drawing.open — and the new document has no dispatcher,
;;;   so every subsequent command times out and the server looks dead.
;;;
;;;   AutoCAD loads acaddoc.lsp from the support file search path once per
;;;   document, as each document opens. Putting the load here means the
;;;   dispatcher follows you into every drawing.
;;;
;;; INSTALL
;;;   1. OPTIONS > Files > Support File Search Path > add this lisp-code folder.
;;;   2. OPTIONS > Files > Trusted Locations > add the same folder.
;;;      Without this, SECURELOAD blocks the load with a modal dialog — which
;;;      also blocks the IPC channel, since the dispatcher can't run while a
;;;      dialog is open.
;;;   3. Restart AutoCAD, or open a new drawing to test.
;;;
;;;   If you already have an acaddoc.lsp elsewhere on the search path, AutoCAD
;;;   loads only the first one found. Copy the (load ...) line below into it
;;;   rather than shipping two.

(if (not c:mcp-dispatch)
  (progn
    ;; findfile resolves against the support search path, so this works
    ;; wherever the repo lives once step 1 above is done. mcp_dispatch.lsp is
    ;; a loader — it locates the mcp_*.lsp modules the same way, which is why
    ;; the search path entry is required rather than merely convenient.
    (setq *mcp-dispatch-path* (findfile "mcp_dispatch.lsp"))
    (if *mcp-dispatch-path*
      (load *mcp-dispatch-path*)
      (princ "\nMCP: mcp_dispatch.lsp not on the support file search path — see acaddoc.lsp header.")
    )
  )
)
(princ)
