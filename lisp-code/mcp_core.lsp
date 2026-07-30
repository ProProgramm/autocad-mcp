;;; mcp_core.lsp — shared helpers, command registry, dispatcher
;;;
;;; Part of the AutoCAD MCP dispatcher. Loaded by mcp_dispatch.lsp.
;;; Commands register themselves at the bottom of this file, so adding
;;; one touches only this module — there is no central dispatch table.

(if (not report-error)
  (defun report-error (msg) (princ (strcat "\nERROR: " msg)))
)

(setq *mcp-ipc-dir* "C:/temp/")

;; -----------------------------------------------------------------------
;; Command registry
;;
;; Handlers register themselves from their own module rather than being
;; listed in one central cond. That keeps adding a command to a single file
;; and removes the shared table every change used to collide on.
;;
;; This is still a whitelist: only registered names can be dispatched, and
;; caller input is never evaluated. The registry replaced a cond; it did not
;; replace the security property the cond provided.
;; -----------------------------------------------------------------------

(if (not *mcp-commands*) (setq *mcp-commands* '()))

(defun mcp-register (name fn / existing)
  "Bind a command name to a handler symbol.

   Re-registration replaces the existing entry instead of shadowing it, so
   reloading a module during development leaves the table the same size."
  (setq existing (assoc name *mcp-commands*))
  (if existing
    (setq *mcp-commands* (subst (cons name fn) existing *mcp-commands*))
    (setq *mcp-commands* (cons (cons name fn) *mcp-commands*))
  )
  name
)

(defun mcp-dispatch-command (cmd-name params-json / entry)
  "Invoke the handler registered for cmd-name. Every handler takes one
   argument, the raw command JSON, and returns (ok . payload-or-error)."
  (setq entry (assoc cmd-name *mcp-commands*))
  (if entry
    (apply (cdr entry) (list params-json))
    ;; Distinguish "no such command" from "the module providing it is not
    ;; loaded" — with modules being opt-in, the second is the likely cause.
    (cons nil (strcat "Unknown command: " cmd-name
                      ". No loaded module registered it; "
                      (itoa (length *mcp-commands*))
                      " commands are available. Check the module list in "
                      "mcp_dispatch.lsp — P&ID commands are not loaded by default."))
  )
)

(defun mcp-cmd-list-commands (params-json / acc)
  "Report the registered command names.

   Lets the Python side verify at runtime that the modules it expects are
   actually loaded, rather than discovering a missing one as a failed call."
  (setq acc "")
  (foreach p (vl-sort *mcp-commands* '(lambda (a b) (< (car a) (car b))))
    (if (> (strlen acc) 0) (setq acc (strcat acc ",")))
    (setq acc (strcat acc "\"" (car p) "\""))
  )
  (cons T (strcat "{\"commands\":[" acc "],\"count\":" (itoa (length *mcp-commands*)) "}"))
)

;; These were guarded with (if (not <name>) ...) so an external utility library
;; could supply its own. That also meant reload-modules could never replace
;; them — they are already bound by the previous load, so the guard skips the
;; new definition and a fix appears to do nothing until AutoCAD restarts.
;; Defined unconditionally instead; load your own copy afterwards to override.

(defun mcp-color-to-aci (color / n)
  "Map a colour name or numeric string to an AutoCAD Color Index.

   Mirrors the ezdxf backend's mapping so both backends interpret the same
   input identically. Unknown names fall back to 7 (white), matching it."
  (cond
    ((not color) 7)
    ((= (type color) 'INT) color)
    ((setq n (atoi color))
     ;; atoi returns 0 for non-numeric text, so only trust a leading digit.
     (if (and (> (strlen color) 0)
              (member (substr color 1 1) '("0" "1" "2" "3" "4" "5" "6" "7" "8" "9")))
       n
       (mcp-color-name-to-aci color)))
    (t (mcp-color-name-to-aci color))
  )
)

(defun mcp-color-name-to-aci (color / hit)
  (setq hit (assoc (strcase color)
                   '(("RED" . 1) ("YELLOW" . 2) ("GREEN" . 3) ("CYAN" . 4)
                     ("BLUE" . 5) ("MAGENTA" . 6) ("WHITE" . 7)
                     ("GREY" . 8) ("GRAY" . 8))))
  (if hit (cdr hit) 7)
)

(defun ensure_layer_exists (name color linetype / aci ltype)
  "Create a layer if absent. Returns T when the layer exists afterwards.

   entmake writes the layer table record directly. The previous version drove
   (command \"_.-LAYER\" \"_NEW\" name \"_COLOR\" color name ...), whose prompt
   sequence varies with drawing state — when it desynced the layer was created
   but the colour was not applied, and the function failed with no message."
  (setq aci (mcp-color-to-aci color))
  ;; entmake rejects a linetype that is not loaded in this drawing. CONTINUOUS
  ;; always exists, so fall back rather than fail; the caller is told.
  (setq ltype (if (and linetype (tblsearch "LTYPE" linetype)) linetype "CONTINUOUS"))
  (if (tblsearch "LAYER" name)
    T
    (if (entmake (list '(0 . "LAYER")
                       '(100 . "AcDbSymbolTableRecord")
                       '(100 . "AcDbLayerTableRecord")
                       (cons 2 name)
                       (cons 70 0)
                       (cons 62 aci)
                       (cons 6 ltype)))
      T
      nil
    )
  )
)

(defun set_current_layer (name)
  "Set a layer as current."
  (setvar "CLAYER" name)
)

(defun set_attribute_value (ent tag value / sub-ent ent-data)
  "Set an attribute value on a block insert by tag name."
  (setq sub-ent (entnext ent))
  (while sub-ent
    (setq ent-data (entget sub-ent))
    (if (and (= (cdr (assoc 0 ent-data)) "ATTRIB")
             (= (strcase (cdr (assoc 2 ent-data))) (strcase tag)))
      (progn
        (entmod (subst (cons 1 value) (assoc 1 ent-data) ent-data))
        (entupd sub-ent)
        (setq sub-ent nil)  ; stop
      )
      (if (= (cdr (assoc 0 ent-data)) "SEQEND")
        (setq sub-ent nil)
        (setq sub-ent (entnext sub-ent))
      )
    )
  )
)

(defun mcp-write-result (filepath request-id ok-flag payload error-msg / fp)

  "Write a result JSON file. Atomic: write to .tmp then rename."
  (setq tmp-path (strcat filepath ".tmp"))
  (setq fp (open tmp-path "w"))
  (if fp
    (progn
      (write-line "{" fp)
      (write-line (strcat "  \"request_id\": \"" request-id "\",") fp)
      (if ok-flag
        (progn
          (write-line "  \"ok\": true," fp)
          (write-line (strcat "  \"payload\": " payload) fp)
        )
        (progn
          (write-line "  \"ok\": false," fp)
          (write-line (strcat "  \"error\": \"" (mcp-escape-string error-msg) "\"") fp)
        )
      )
      (write-line "}" fp)
      (close fp)
      ;; Rename .tmp to final path (atomic on NTFS)
      (vl-file-rename tmp-path filepath)
    )
    (princ (strcat "\nMCP: Cannot open result file: " tmp-path))
  )
)

(defun mcp-escape-string (s / result i ch)
  "Escape quotes and backslashes in a string for JSON."
  (if (null s) (setq s ""))
  (setq result "" i 1)
  (while (<= i (strlen s))
    (setq ch (substr s i 1))
    (cond
      ((= ch "\"") (setq result (strcat result "\\\"")))
      ((= ch "\\") (setq result (strcat result "\\\\")))
      (t (setq result (strcat result ch)))
    )
    (setq i (1+ i))
  )
  result
)

(defun mcp-read-file-lines (filepath / fp line lines)
  "Read all lines from a file into a single string."
  (setq fp (open filepath "r"))
  (if (not fp) (progn (princ (strcat "\nMCP: Cannot read: " filepath)) nil)
    (progn
      (setq lines "")
      (while (setq line (read-line fp))
        (setq lines (strcat lines line))
      )
      (close fp)
      lines
    )
  )
)

(defun mcp-json-get-string (json key / search-str pos end-pos value)
  "Extract a string value for a given key from JSON text."
  (setq search-str (strcat "\"" key "\""))
  (setq pos (vl-string-search search-str json))
  (if (null pos) nil
    (progn
      ;; Find the colon after key
      (setq pos (vl-string-search ":" json pos))
      (if (null pos) nil
        (progn
          ;; Find opening quote of value
          (setq pos (vl-string-search "\"" json (1+ pos)))
          (if (null pos) nil
            (progn
              (setq pos (+ pos 2))  ; 0-based search result + 2 = 1-based position after quote
              ;; Find closing quote (skip escaped quotes)
              (setq end-pos pos)
              (while (and (<= end-pos (strlen json))
                          (or (= end-pos pos)
                              (/= (substr json end-pos 1) "\"")))
                ;; Handle escaped characters
                (if (= (substr json end-pos 1) "\\")
                  (setq end-pos (+ end-pos 2))
                  (setq end-pos (1+ end-pos))
                )
              )
              (substr json pos (- end-pos pos))
            )
          )
        )
      )
    )
  )
)

(defun mcp-json-get-number (json key / search-str pos num-start num-end ch)
  "Extract a number value for a given key from JSON text."
  (setq search-str (strcat "\"" key "\""))
  (setq pos (vl-string-search search-str json))
  (if (null pos) nil
    (progn
      (setq pos (vl-string-search ":" json pos))
      (if (null pos) nil
        (progn
          (setq pos (+ pos 2))  ; 0-based search result + 2 = 1-based position after colon
          ;; Skip whitespace
          (while (and (<= pos (strlen json))
                      (member (substr json pos 1) '(" " "\t" "\n")))
            (setq pos (1+ pos))
          )
          ;; Read number
          (setq num-start pos num-end pos)
          (while (and (<= num-end (strlen json))
                      (or (member (substr json num-end 1) '("0" "1" "2" "3" "4" "5" "6" "7" "8" "9" "." "-" "+"))
                      ))
            (setq num-end (1+ num-end))
          )
          (atof (substr json num-start (- num-end num-start)))
        )
      )
    )
  )
)

(defun mcp-split-string (str delim / pos result token)
  "Split a string by single-char delimiter. Returns a list of strings."
  (setq result '())
  (while (setq pos (vl-string-search delim str))
    (setq token (substr str 1 pos))
    (setq result (append result (list token)))
    (setq str (substr str (+ pos 2)))
  )
  (setq result (append result (list str)))
  result
)

(defun mcp-pt-json (pt)
  "Format a DXF point as a JSON [x,y] pair. Returns null for a missing point."
  (if pt
    (strcat "[" (rtos (car pt) 2 6) "," (rtos (cadr pt) 2 6) "]")
    "null"
  )
)

(defun mcp-num-json (n default)
  "Format a number as JSON, substituting a default when the group is absent."
  (rtos (if n n default) 2 6)
)

(defun mcp-deg-json (rad)
  "DXF stores angles in radians; the create/rotate API speaks degrees.
   Convert on read so values round-trip through this server unchanged."
  (rtos (if rad (* 180.0 (/ rad pi)) 0.0) 2 6)
)

(defun mcp-mtext-string (ent-data / txt)
  "MTEXT longer than 250 chars is split across group 3 chunks with the
   remainder in group 1. Concatenate in DXF order to recover the full string."
  (setq txt "")
  (foreach itm ent-data
    (if (= (car itm) 3) (setq txt (strcat txt (cdr itm))))
  )
  (strcat txt (if (assoc 1 ent-data) (cdr (assoc 1 ent-data)) ""))
)

;; -----------------------------------------------------------------------
;; Entry point — Python types (c:mcp-dispatch) into the command line
;; -----------------------------------------------------------------------

(defun c:mcp-dispatch ( / cmd-files cmd-file json-text request-id cmd-name result result-file)
  "Find pending command file, dispatch, write result."
  ;; Find first pending command file
  (setq cmd-files (vl-directory-files *mcp-ipc-dir* "autocad_mcp_cmd_*.json" 1))
  (if (not cmd-files)
    (progn (princ "\nMCP: No pending commands") (princ))
    (progn
      ;; Process first command
      (setq cmd-file (strcat *mcp-ipc-dir* (car cmd-files)))
      (setq json-text (mcp-read-file-lines cmd-file))

      (if (not json-text)
        (princ "\nMCP: Cannot read command file")
        (progn
          ;; Parse command
          (setq request-id (mcp-json-get-string json-text "request_id"))
          (setq cmd-name (mcp-json-get-string json-text "command"))

          (if (not cmd-name)
            (princ "\nMCP: No command in payload")
            (progn
              (princ (strcat "\nMCP: Dispatching " cmd-name " [" request-id "]"))

              ;; Execute via the registry — unregistered names are refused
              (setq result
                (vl-catch-all-apply
                  'mcp-dispatch-command
                  (list cmd-name json-text)
                )
              )

              ;; Handle error from vl-catch-all-apply
              (if (vl-catch-all-error-p result)
                (setq result (cons nil (vl-catch-all-error-message result)))
              )

              ;; Write result. A handler that fails without a message would
              ;; otherwise surface as ok:false with an empty string, which says
              ;; nothing about what went wrong — name the command instead.
              (setq result-file (strcat *mcp-ipc-dir* "autocad_mcp_result_" request-id ".json"))
              (if (car result)
                (mcp-write-result result-file request-id T (cdr result) nil)
                (mcp-write-result result-file request-id nil nil
                  (if (and (cdr result) (= (type (cdr result)) 'STR) (> (strlen (cdr result)) 0))
                    (cdr result)
                    (strcat "Command '" cmd-name "' failed without an error message")
                  )
                )
              )

              (princ (strcat "\nMCP: Done " cmd-name))
            )
          )

          ;; Clean up command file
          (vl-file-delete cmd-file)
        )
      )
    )
  )
  (princ)
)

(defun mcp-cmd-reload-modules (params-json / path old-secureload result)
  "Re-load every module without restarting AutoCAD.

   Editing a module otherwise means reloading by hand in the drawing before
   the change takes effect. Re-registration replaces entries rather than
   stacking them, so this is safe to call repeatedly. It cannot rescue a
   broken core — dispatching this command already requires a working
   dispatcher — but it covers the ordinary edit-and-retry loop."
  ;; Resolve the same way the loader does — it may have been loaded by
  ;; absolute path, in which case findfile alone will not see it.
  (setq path (if mcp-find-module
               (mcp-find-module "mcp_dispatch.lsp")
               (findfile "mcp_dispatch.lsp")))
  (if (not path)
    (cons nil (strcat "mcp_dispatch.lsp not found. Add lisp-code to the Support "
                      "File Search Path, or set *mcp-lisp-dir* before loading it."))
    (progn
      (setq old-secureload (getvar "SECURELOAD"))
      (setvar "SECURELOAD" 0)
      (setq result (vl-catch-all-apply 'load (list path)))
      (setvar "SECURELOAD" old-secureload)
      (if (vl-catch-all-error-p result)
        (cons nil (strcat "Reload failed: " (vl-catch-all-error-message result)))
        (cons T (strcat "{\"reloaded\":true,\"commands\":" (itoa (length *mcp-commands*)) "}"))
      )
    )
  )
)

;; --- command registration ---

(mcp-register "list-commands" 'mcp-cmd-list-commands)
(mcp-register "reload-modules" 'mcp-cmd-reload-modules)

(princ "\n  mcp_core loaded (2 commands)")
(princ)
