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

(defun mcp-layer-set-flag (name bit on / rec d flags)
  "Set or clear a bit in a layer's flag group (70). Returns T on success.

   entmod on the table record rather than (command \"_.-LAYER\" ...), whose
   prompt sequence depends on drawing state and fails silently when it desyncs."
  (setq rec (tblobjname "LAYER" name))
  (if (not rec)
    nil
    (progn
      (setq d (entget rec))
      (setq flags (cdr (assoc 70 d)))
      (setq flags (if on (logior flags bit) (logand flags (~ bit))))
      (entmod (subst (cons 70 flags) (assoc 70 d) d))
      T
    )
  )
)

(defun mcp-cmd-layer-create (params / name color linetype aci ltype fallback)
  (setq name (mcp-json-get-string params "name"))
  (if (not name)
    (cons nil "name is required")
    (progn
      (setq color (mcp-json-get-string params "color"))
      (setq linetype (mcp-json-get-string params "linetype"))
      (if (not linetype) (setq linetype "CONTINUOUS"))
      (setq aci (mcp-color-to-aci color))
      ;; A linetype that is not loaded in this drawing would make entmake fail
      ;; outright; substituting CONTINUOUS and saying so beats refusing.
      (setq fallback (not (tblsearch "LTYPE" linetype)))
      (setq ltype (if fallback "CONTINUOUS" linetype))
      (if (ensure_layer_exists name color ltype)
        (cons T (strcat "{\"name\":\"" (mcp-escape-string name) "\""
                        ",\"color\":" (itoa aci)
                        ",\"linetype\":\"" (mcp-escape-string ltype) "\""
                        ",\"linetype_fallback\":" (if fallback "true" "false")
                        "}"))
        (cons nil (strcat "Could not create layer " name
                          " — entmake rejected the layer table record"))
      )
    )
  )
)

(defun mcp-cmd-layer-set-current (params / name)
  (setq name (mcp-json-get-string params "name"))
  (setvar "CLAYER" name)
  (cons T (strcat "{\"current_layer\":\"" name "\"}"))
)

(defun mcp-cmd-layer-set-properties (params / name color linetype lineweight
                                            rec d applied)
  (setq name (mcp-json-get-string params "name"))
  (setq rec (if name (tblobjname "LAYER" name)))
  (if (not rec)
    (cons nil (strcat "Layer not found: " (if name name "(none given)")))
    (progn
      (setq color (mcp-json-get-string params "color"))
      (setq linetype (mcp-json-get-string params "linetype"))
      (setq lineweight (mcp-json-get-string params "lineweight"))
      (setq d (entget rec) applied "")

      (if color
        (progn
          (setq d (subst (cons 62 (mcp-color-to-aci color)) (assoc 62 d) d))
          (setq applied (strcat applied "color "))
        )
      )
      ;; Silently ignoring an unloaded linetype would report success while
      ;; changing nothing, so refuse instead.
      (if linetype
        (if (tblsearch "LTYPE" linetype)
          (progn
            (setq d (subst (cons 6 linetype) (assoc 6 d) d))
            (setq applied (strcat applied "linetype "))
          )
          (setq applied (strcat applied "[linetype-not-loaded] "))
        )
      )
      (if lineweight
        (progn
          ;; Group 370 is hundredths of a millimetre, or -3 default / -2
          ;; byblock / -1 bylayer.
          (setq d (if (assoc 370 d)
                    (subst (cons 370 (atoi lineweight)) (assoc 370 d) d)
                    (append d (list (cons 370 (atoi lineweight))))))
          (setq applied (strcat applied "lineweight "))
        )
      )

      (if (entmod d)
        (cons T (strcat "{\"name\":\"" (mcp-escape-string name) "\""
                        ",\"applied\":\"" (vl-string-trim " " applied) "\"}"))
        (cons nil (strcat "entmod rejected the change to layer " name))
      )
    )
  )
)

(defun mcp-cmd-layer-freeze (params / name)
  (setq name (mcp-json-get-string params "name"))
  ;; AutoCAD refuses to freeze the current layer; entmod would let it through
  ;; and leave the drawing in a state the UI cannot produce.
  (cond
    ((not (tblsearch "LAYER" name))
     (cons nil (strcat "Layer not found: " name)))
    ((= (strcase name) (strcase (getvar "CLAYER")))
     (cons nil (strcat "Cannot freeze the current layer (" name
                       ") — set another layer current first")))
    ((mcp-layer-set-flag name 1 T)
     (cons T (strcat "{\"name\":\"" (mcp-escape-string name) "\",\"frozen\":true}")))
    (t (cons nil (strcat "Could not freeze layer " name)))
  )
)

(defun mcp-cmd-layer-thaw (params / name)
  (setq name (mcp-json-get-string params "name"))
  (if (mcp-layer-set-flag name 1 nil)
    (cons T (strcat "{\"name\":\"" (mcp-escape-string name) "\",\"frozen\":false}"))
    (cons nil (strcat "Layer not found: " name))
  )
)

(defun mcp-cmd-layer-lock (params / name)
  (setq name (mcp-json-get-string params "name"))
  (if (mcp-layer-set-flag name 4 T)
    (cons T (strcat "{\"name\":\"" (mcp-escape-string name) "\",\"locked\":true}"))
    (cons nil (strcat "Layer not found: " name))
  )
)

(defun mcp-cmd-layer-unlock (params / name)
  (setq name (mcp-json-get-string params "name"))
  (if (mcp-layer-set-flag name 4 nil)
    (cons T (strcat "{\"name\":\"" (mcp-escape-string name) "\",\"locked\":false}"))
    (cons nil (strcat "Layer not found: " name))
  )
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
