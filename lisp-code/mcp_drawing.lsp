;;; mcp_drawing.lsp — drawing file management, undo/redo
;;;
;;; Part of the AutoCAD MCP dispatcher. Loaded by mcp_dispatch.lsp.
;;; Commands register themselves at the bottom of this file, so adding
;;; one touches only this module — there is no central dispatch table.

(defun mcp-cmd-drawing-info (params-json / count layers layer-list layer-count)
  "Return drawing info: entity count, layer count, sample of layer names.

   An xref-assembled drawing can carry thousands of layers; emitting every
   name produced a payload far larger than any caller could use (4169 layers
   ran to 330 KB). Report the count, which is what callers actually branch on,
   and a sample. Use the layer tool for a filtered or paged list."
  (setq count 0)
  (setq ent (entnext))
  (while ent
    (setq count (1+ count))
    (setq ent (entnext ent))
  )
  (setq layer-list "" layer-count 0)
  (setq layers (tblnext "LAYER" T))
  (while layers
    (if (< layer-count 25)
      (progn
        (if (> (strlen layer-list) 0) (setq layer-list (strcat layer-list ",")))
        (setq layer-list (strcat layer-list "\"" (mcp-escape-string (cdr (assoc 2 layers))) "\""))
      )
    )
    (setq layer-count (1+ layer-count))
    (setq layers (tblnext "LAYER"))
  )
  (cons T (strcat "{\"entity_count\":" (itoa count)
                  ",\"layer_count\":" (itoa layer-count)
                  ",\"layers\":[" layer-list "]"
                  ",\"layers_truncated\":" (if (> layer-count 25) "true" "false")
                  "}"))
)

(defun mcp-cmd-drawing-create (params / ss)
  "Reset current drawing to a clean state (erase all, purge, reset to layer 0).
   Using _.NEW would create a new document tab with a fresh LISP namespace,
   breaking the IPC dispatcher. This approach preserves the dispatcher."
  (if (setq ss (ssget "_X"))
    (progn (command "_.ERASE" ss "") (setq ss nil))
  )
  (setvar "CLAYER" "0")
  (command "_.-PURGE" "_ALL" "*" "_N")
  (cons T (strcat "{\"drawing\":\"" (mcp-escape-string (getvar "DWGNAME")) "\"}"))
)

(defun mcp-cmd-drawing-get-variables (params / names-str result var-list var-name var-val first-var)
  (setq names-str (mcp-json-get-string params "names_str"))
  (if (or (not names-str) (= names-str ""))
    ;; Default set when no specific names requested
    (progn
      (setq result "{")
      (setq result (strcat result "\"ACADVER\":\"" (getvar "ACADVER") "\""))
      (setq result (strcat result ",\"DWGNAME\":\"" (mcp-escape-string (getvar "DWGNAME")) "\""))
      (setq result (strcat result ",\"CLAYER\":\"" (getvar "CLAYER") "\""))
      (setq result (strcat result "}"))
      (cons T result)
    )
    ;; Parse semicolon-delimited variable names
    (progn
      (setq var-list (mcp-split-string names-str ";"))
      (setq result "{" first-var T)
      (foreach var-name var-list
        (setq var-val (getvar var-name))
        (if (not first-var) (setq result (strcat result ",")))
        (setq first-var nil)
        (if (not var-val)
          (setq result (strcat result "\"" var-name "\":null"))
          (cond
            ((= (type var-val) 'STR)
             (setq result (strcat result "\"" var-name "\":\"" (mcp-escape-string var-val) "\"")))
            ((= (type var-val) 'INT)
             (setq result (strcat result "\"" var-name "\":" (itoa var-val))))
            ((= (type var-val) 'REAL)
             (setq result (strcat result "\"" var-name "\":" (rtos var-val 2 6))))
            (t
             (setq result (strcat result "\"" var-name "\":\"" (mcp-escape-string (vl-princ-to-string var-val)) "\"")))
          )
        )
      )
      (setq result (strcat result "}"))
      (cons T result)
    )
  )
)

(defun mcp-cmd-drawing-plot-pdf (params / path)
  (setq path (mcp-json-get-string params "path"))
  (if path
    (progn
      (command "_.-PLOT" "_Y" "" "DWG To PDF.pc3"
        "ANSI_A_(8.50_x_11.00_Inches)" "_Inches" "_Landscape"
        "_N" "_Extents" "_Fit" "_Y" "acad.ctb" "_Y" "_N" "_Y" path "_Y")
      (cons T (strcat "{\"path\":\"" (mcp-escape-string path) "\"}")))
    (cons nil "Plot path required")
  )
)

(defun mcp-cmd-undo (params-json)
  (command "_.UNDO" "1")
  (cons T "\"undone\"")
)

(defun mcp-cmd-redo (params-json)
  (command "_.REDO")
  (cons T "\"redone\"")
)

(defun mcp-cmd-drawing-save (params-json / path)
  (progn
         (setq path (mcp-json-get-string params-json "path"))
         (if (and path (> (strlen path) 0))
           (progn
             (setvar "FILEDIA" 0)
             (command "_.SAVEAS" "" path)
             (setvar "FILEDIA" 1)
             (cons T (strcat "\"saved to: " (mcp-escape-string path) "\"")))
           (progn (command "_.QSAVE") (cons T "\"saved\""))))
)

(defun mcp-cmd-drawing-save-as-dxf (params-json / path)
  (progn
         (setq path (mcp-json-get-string params-json "path"))
         (if path
           (progn (command "_.SAVEAS" "DXF" path) (cons T (strcat "\"" path "\"")))
           (cons nil "Save path required")))
)

(defun mcp-cmd-drawing-purge (params-json)
  (command "_.-PURGE" "_ALL" "*" "_N")
  (cons T "\"purged\"")
)

(defun mcp-cmd-drawing-open (params-json / path)
  (progn
         (setq path (mcp-json-get-string params-json "path"))
         (if path
           (progn
             (setvar "FILEDIA" 0)
             (command "_.OPEN" path)
             (setvar "FILEDIA" 1)
             (cons T (strcat "\"opened: " (mcp-escape-string path) "\"")))
           (cons nil "Path required")))
)

;; --- command registration ---

(mcp-register "drawing-create" 'mcp-cmd-drawing-create)
(mcp-register "drawing-get-variables" 'mcp-cmd-drawing-get-variables)
(mcp-register "drawing-info" 'mcp-cmd-drawing-info)
(mcp-register "drawing-open" 'mcp-cmd-drawing-open)
(mcp-register "drawing-plot-pdf" 'mcp-cmd-drawing-plot-pdf)
(mcp-register "drawing-purge" 'mcp-cmd-drawing-purge)
(mcp-register "drawing-save" 'mcp-cmd-drawing-save)
(mcp-register "drawing-save-as-dxf" 'mcp-cmd-drawing-save-as-dxf)
(mcp-register "redo" 'mcp-cmd-redo)
(mcp-register "undo" 'mcp-cmd-undo)

(princ "\n  mcp_drawing loaded (10 commands)")
(princ)
