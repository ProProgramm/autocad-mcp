;;; mcp_view.lsp — viewport control
;;;
;;; Part of the AutoCAD MCP dispatcher. Loaded by mcp_dispatch.lsp.
;;; Commands register themselves at the bottom of this file, so adding
;;; one touches only this module — there is no central dispatch table.

(defun mcp-cmd-zoom-extents (params-json)
  (command "_.ZOOM" "_E")
  (cons T "\"zoomed to extents\"")
)

(defun mcp-cmd-zoom-window (params-json / x1 x2 y1 y2)
  (progn
         (setq x1 (mcp-json-get-number params-json "x1"))
         (setq y1 (mcp-json-get-number params-json "y1"))
         (setq x2 (mcp-json-get-number params-json "x2"))
         (setq y2 (mcp-json-get-number params-json "y2"))
         (command "_.ZOOM" "_W" (list x1 y1 0) (list x2 y2 0))
         (cons T "\"zoomed to window\""))
)

;; --- command registration ---

(mcp-register "zoom-extents" 'mcp-cmd-zoom-extents)
(mcp-register "zoom-window" 'mcp-cmd-zoom-window)

(princ "\n  mcp_view loaded (2 commands)")
(princ)
