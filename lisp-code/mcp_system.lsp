;;; mcp_system.lsp — ping and freehand LISP execution
;;;
;;; Part of the AutoCAD MCP dispatcher. Loaded by mcp_dispatch.lsp.
;;; Commands register themselves at the bottom of this file, so adding
;;; one touches only this module — there is no central dispatch table.

(defun mcp-cmd-execute-lisp (params / code-file result old-secureload lower)
  (setq code-file (mcp-json-get-string params "code_file"))
  (if (not code-file)
    (cons nil "code_file parameter required")
    (if (not (findfile code-file))
      (cons nil (strcat "Code file not found: " code-file))
      (progn
        ;; When the IPC directory is a trusted path — which acaddoc.lsp arranges
        ;; — the load needs no help and SECURELOAD is left alone. Lowering it
        ;; globally on every call widened the window for any other load in the
        ;; session, and made the variable unreadable from inside this function:
        ;; a probe here always saw 0 regardless of the real setting.
        (setq lower (not (mcp-path-trusted-p code-file)))
        (if lower
          (progn
            (setq old-secureload (getvar "SECURELOAD"))
            (setvar "SECURELOAD" 0)
          )
        )
        (setq result (vl-catch-all-apply 'load (list code-file)))
        (if lower (setvar "SECURELOAD" old-secureload))
        (if (vl-catch-all-error-p result)
          (cons nil (strcat "LISP error: " (vl-catch-all-error-message result)))
          (cons T (strcat "\"" (mcp-escape-string (vl-princ-to-string result)) "\""))
        )
      )
    )
  )
)

(defun mcp-cmd-ping (params-json)
  (cons T "\"pong\"")
)

;; --- command registration ---

(mcp-register "execute-lisp" 'mcp-cmd-execute-lisp)
(mcp-register "ping" 'mcp-cmd-ping)

(princ "\n  mcp_system loaded (2 commands)")
(princ)
