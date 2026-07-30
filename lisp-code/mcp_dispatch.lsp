;;; mcp_dispatch.lsp — module loader for the AutoCAD MCP dispatcher (v3.3)
;;;
;;; Protocol:
;;;   1. Python writes command JSON to C:/temp/autocad_mcp_cmd_{id}.json
;;;   2. Python types "(c:mcp-dispatch)" + Enter
;;;   3. The dispatcher reads cmd, looks up the handler, writes result JSON
;;;   4. Python polls for C:/temp/autocad_mcp_result_{id}.json
;;;
;;; SECURITY: No raw eval. Handlers are looked up in a registry that only
;;; contains names the modules registered — caller input is never evaluated.
;;;
;;; This file used to hold every command in one 1700-line file with a single
;;; 260-line cond. Commands now live in per-domain modules and register
;;; themselves, so adding one touches a single file. Loading this file loads
;;; them all, which keeps existing APPLOAD instructions working.
;;;
;;; Compatible with AutoCAD LT 2024+, except where noted per command
;;; (dynamic block name resolution needs ActiveX, which LT lacks).

;; mcp_core must load first: it defines mcp-register, which every other
;; module calls at load time.
(setq *mcp-modules*
  (list
    "mcp_core.lsp"
    "mcp_system.lsp"
    "mcp_drawing.lsp"
    "mcp_entity.lsp"
    "mcp_layer.lsp"
    "mcp_block.lsp"
    "mcp_annotation.lsp"
    "mcp_view.lsp"
    ;; "mcp_pid.lsp"   ; P&ID symbols — add this line if you need them
  )
)

(defun mcp-load-modules ( / found missing path)
  "Load each module from the support file search path.

   Modules are located with findfile rather than a hardcoded path so the repo
   can live anywhere, which means this folder must be on the Support File
   Search Path — the same requirement acaddoc.lsp already has. A module that
   fails to load takes only its own commands down, not the whole dispatcher."
  (setq found 0 missing "")
  (foreach m *mcp-modules*
    (setq path (findfile m))
    (if path
      (progn (load path) (setq found (1+ found)))
      (setq missing (strcat missing " " m))
    )
  )
  (if (> (strlen missing) 0)
    (progn
      (princ "\n*** MCP: modules not found on the support file search path:")
      (princ missing)
      (princ "\n*** Add the lisp-code folder under OPTIONS > Files > Support File Search Path.")
    )
  )
  found
)

(mcp-load-modules)

(princ "\n=== MCP Dispatch v3.3 loaded ===")
(princ "\nIPC directory: ")
(princ *mcp-ipc-dir*)
(princ (strcat "\nCommands registered: " (itoa (length *mcp-commands*))))
(princ "\nReady for commands via (c:mcp-dispatch)")
(princ)
