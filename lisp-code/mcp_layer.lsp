;;; mcp_layer.lsp — layer management
;;;
;;; Part of the AutoCAD MCP dispatcher. Loaded by mcp_dispatch.lsp.
;;; Commands register themselves at the bottom of this file, so adding
;;; one touches only this module — there is no central dispatch table.

(defun mcp-cmd-layer-list (params / filter limit offset layers layer-list name total emitted)
  "Return layers, filtered by name substring and capped.

   Same reasoning as entity-list: on an xref-assembled drawing the layer table
   runs to thousands of entries, so returning all of them is useless to the
   caller and expensive to build. `filter` is a case-insensitive substring
   match, which is how you actually find a layer among 4000."
  (setq filter (mcp-json-get-string params "filter"))
  (setq limit  (mcp-json-get-number params "limit"))
  (setq offset (mcp-json-get-number params "offset"))
  (if limit  (setq limit  (fix limit))  (setq limit 200))
  (if offset (setq offset (fix offset)) (setq offset 0))
  (if (< limit 0)  (setq limit 0))
  (if (< offset 0) (setq offset 0))
  (if filter (setq filter (strcase filter)))

  (setq layer-list "" total 0 emitted 0)
  (setq layers (tblnext "LAYER" T))
  (while layers
    (setq name (cdr (assoc 2 layers)))
    (if (or (not filter) (vl-string-search filter (strcase name)))
      (progn
        (setq total (1+ total))
        (if (and (> total offset) (< emitted limit))
          (progn
            (if (> (strlen layer-list) 0) (setq layer-list (strcat layer-list ",")))
            (setq layer-list (strcat layer-list
              "{\"name\":\"" (mcp-escape-string name)
              "\",\"color\":" (itoa (cdr (assoc 62 layers))) "}"))
            (setq emitted (1+ emitted))
          )
        )
      )
    )
    (setq layers (tblnext "LAYER"))
  )
  (cons T (strcat "{\"layers\":[" layer-list "]"
                  ",\"returned\":" (itoa emitted)
                  ",\"offset\":" (itoa offset)
                  ",\"total\":" (itoa total)
                  ",\"truncated\":" (if (> total (+ offset emitted)) "true" "false")
                  "}"))
)

(defun mcp-cmd-layer-create (params / name color linetype)
  (setq name (mcp-json-get-string params "name"))
  (setq color (mcp-json-get-string params "color"))
  (setq linetype (mcp-json-get-string params "linetype"))
  (if (not color) (setq color "white"))
  (if (not linetype) (setq linetype "CONTINUOUS"))
  (ensure_layer_exists name color linetype)
  (cons T (strcat "{\"name\":\"" name "\"}"))
)

(defun mcp-cmd-layer-set-current (params / name)
  (setq name (mcp-json-get-string params "name"))
  (setvar "CLAYER" name)
  (cons T (strcat "{\"current_layer\":\"" name "\"}"))
)

(defun mcp-cmd-layer-set-properties (params / name color linetype lineweight)
  (setq name (mcp-json-get-string params "name"))
  (setq color (mcp-json-get-string params "color"))
  (setq linetype (mcp-json-get-string params "linetype"))
  (setq lineweight (mcp-json-get-string params "lineweight"))
  (if color (command "_.-LAYER" "_COLOR" color name ""))
  (if linetype (command "_.-LAYER" "_LTYPE" linetype name ""))
  (if lineweight (command "_.-LAYER" "_LWEIGHT" lineweight name ""))
  (cons T (strcat "{\"name\":\"" name "\"}"))
)

(defun mcp-cmd-layer-freeze (params / name)
  (setq name (mcp-json-get-string params "name"))
  (command "_.-LAYER" "_FREEZE" name "")
  (cons T (strcat "{\"name\":\"" name "\",\"frozen\":true}"))
)

(defun mcp-cmd-layer-thaw (params / name)
  (setq name (mcp-json-get-string params "name"))
  (command "_.-LAYER" "_THAW" name "")
  (cons T (strcat "{\"name\":\"" name "\",\"frozen\":false}"))
)

(defun mcp-cmd-layer-lock (params / name)
  (setq name (mcp-json-get-string params "name"))
  (command "_.-LAYER" "_LOCK" name "")
  (cons T (strcat "{\"name\":\"" name "\",\"locked\":true}"))
)

(defun mcp-cmd-layer-unlock (params / name)
  (setq name (mcp-json-get-string params "name"))
  (command "_.-LAYER" "_UNLOCK" name "")
  (cons T (strcat "{\"name\":\"" name "\",\"locked\":false}"))
)

;; --- command registration ---

(mcp-register "layer-create" 'mcp-cmd-layer-create)
(mcp-register "layer-freeze" 'mcp-cmd-layer-freeze)
(mcp-register "layer-list" 'mcp-cmd-layer-list)
(mcp-register "layer-lock" 'mcp-cmd-layer-lock)
(mcp-register "layer-set-current" 'mcp-cmd-layer-set-current)
(mcp-register "layer-set-properties" 'mcp-cmd-layer-set-properties)
(mcp-register "layer-thaw" 'mcp-cmd-layer-thaw)
(mcp-register "layer-unlock" 'mcp-cmd-layer-unlock)

(princ "\n  mcp_layer loaded (8 commands)")
(princ)
