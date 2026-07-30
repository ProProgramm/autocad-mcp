;;; mcp_block.lsp — block insertion, attributes, bulk extraction
;;;
;;; Part of the AutoCAD MCP dispatcher. Loaded by mcp_dispatch.lsp.
;;; Commands register themselves at the bottom of this file, so adding
;;; one touches only this module — there is no central dispatch table.

(setq *mcp-effname-cache* '())

(defun mcp-effective-name (ent raw / cached res)
  "Resolve a dynamic block instance to the name the drafter knows.

   A dynamic block whose parameters differ from the definition is stored under
   an anonymous name like *U222; the real name (BS013) lives on the ActiveX
   object. Without this, filtering by block name silently misses most blocks in
   a drawing that uses dynamic blocks. Falls back to the raw name on AutoCAD LT,
   which has no ActiveX. Cached: each anonymous name maps to exactly one
   definition, and they repeat heavily."
  (if (/= "*" (substr raw 1 1))
    raw
    (progn
      (setq cached (assoc raw *mcp-effname-cache*))
      (if cached
        (cdr cached)
        (progn
          (setq res (vl-catch-all-apply
                      '(lambda () (vla-get-EffectiveName (vlax-ename->vla-object ent)))))
          (if (or (vl-catch-all-error-p res) (/= (type res) 'STR))
            (setq res raw)
          )
          (setq *mcp-effname-cache* (cons (cons raw res) *mcp-effname-cache*))
          res
        )
      )
    )
  )
)

(defun mcp-attribs-json (ent tags / s sd out tag)
  "Serialize an INSERT's attributes as a JSON object body.

   Only call this when group 66 says attributes follow — otherwise entnext
   walks into the next drawing entity rather than a sub-entity."
  (setq out "" s (entnext ent))
  (while (and s (/= "SEQEND" (cdr (assoc 0 (setq sd (entget s))))))
    (if (= "ATTRIB" (cdr (assoc 0 sd)))
      (progn
        (setq tag (cdr (assoc 2 sd)))
        (if (or (not tags) (member (strcase tag) tags))
          (progn
            (if (> (strlen out) 0) (setq out (strcat out ",")))
            (setq out (strcat out "\"" (mcp-escape-string tag) "\":\""
                              (mcp-escape-string (cdr (assoc 1 sd))) "\""))
          )
        )
      )
    )
    (setq s (entnext s))
  )
  out
)

(defun mcp-cmd-block-extract (params / layer name-filter tags tags-str limit offset
                                     bx1 by1 bx2 by2 use-bbox tmp
                                     e d raw eff pt acc total emitted attrs)
  "Read blocks and their attributes in one round trip.

   This exists because the per-entity path costs an IPC round trip each: a
   drawing with 824 attributed blocks would need 824 dispatches to build a
   Fundamentdatenliste. Cheap filters (layer, bbox) are applied before the
   expensive work — effective-name resolution costs an ActiveX call and
   attribute reading walks sub-entities — so a scoped query stays well inside
   the IPC timeout even on a large drawing."
  (vl-load-com)
  (setq layer       (mcp-json-get-string params "layer"))
  (setq name-filter (mcp-json-get-string params "name"))
  (setq tags-str    (mcp-json-get-string params "tags"))
  (setq limit       (mcp-json-get-number params "limit"))
  (setq offset      (mcp-json-get-number params "offset"))
  (setq bx1 (mcp-json-get-number params "bx1")
        by1 (mcp-json-get-number params "by1")
        bx2 (mcp-json-get-number params "bx2")
        by2 (mcp-json-get-number params "by2"))

  (if limit  (setq limit  (fix limit))  (setq limit 100))
  (if offset (setq offset (fix offset)) (setq offset 0))
  (if (< limit 0)  (setq limit 0))
  (if (< offset 0) (setq offset 0))
  (if name-filter (setq name-filter (strcase name-filter)))
  (if tags-str
    (setq tags (mapcar '(lambda (s) (strcase (vl-string-trim " " s)))
                       (mcp-split-string tags-str ",")))
  )

  (setq use-bbox (and bx1 by1 bx2 by2))
  (if use-bbox
    (progn
      (if (> bx1 bx2) (progn (setq tmp bx1) (setq bx1 bx2) (setq bx2 tmp)))
      (if (> by1 by2) (progn (setq tmp by1) (setq by1 by2) (setq by2 tmp)))
    )
  )

  (setq acc "" total 0 emitted 0 e (entnext))
  (while e
    (setq d (entget e))
    (if (= "INSERT" (cdr (assoc 0 d)))
      (progn
        (setq pt (cdr (assoc 10 d)))
        ;; Cheap filters first — they decide most entities without ActiveX.
        (if (and (or (not layer) (= (cdr (assoc 8 d)) layer))
                 (or (not use-bbox)
                     (and pt (>= (car pt) bx1) (<= (car pt) bx2)
                              (>= (cadr pt) by1) (<= (cadr pt) by2))))
          (progn
            (setq raw (cdr (assoc 2 d)))
            (setq eff (if name-filter (mcp-effective-name e raw) nil))
            (if (or (not name-filter) (vl-string-search name-filter (strcase eff)))
              (progn
                (setq total (1+ total))
                (if (and (> total offset) (< emitted limit))
                  (progn
                    (if (not eff) (setq eff (mcp-effective-name e raw)))
                    (setq attrs
                      (if (and (assoc 66 d) (= 1 (cdr (assoc 66 d))))
                        (mcp-attribs-json e tags)
                        ""))
                    (if (> (strlen acc) 0) (setq acc (strcat acc ",")))
                    (setq acc (strcat acc
                      "{\"handle\":\"" (cdr (assoc 5 d))
                      "\",\"name\":\"" (mcp-escape-string eff)
                      "\",\"layer\":\"" (mcp-escape-string (cdr (assoc 8 d))) "\""
                      (if pt (strcat ",\"pt\":[" (rtos (car pt) 2 3) "," (rtos (cadr pt) 2 3) "]") "")
                      ",\"rotation\":" (mcp-deg-json (cdr (assoc 50 d)))
                      ",\"attribs\":{" attrs "}}"))
                    (setq emitted (1+ emitted))
                  )
                )
              )
            )
          )
        )
      )
    )
    (setq e (entnext e))
  )
  (cons T (strcat "{\"blocks\":[" acc "]"
                  ",\"returned\":" (itoa emitted)
                  ",\"offset\":" (itoa offset)
                  ",\"total\":" (itoa total)
                  ",\"truncated\":" (if (> total (+ offset emitted)) "true" "false")
                  "}"))
)

(defun mcp-cmd-block-insert-with-attribs (params / name x y scale rotation attributes ent)
  (setq name (mcp-json-get-string params "name"))
  (setq x (mcp-json-get-number params "x"))
  (setq y (mcp-json-get-number params "y"))
  (setq scale (mcp-json-get-number params "scale"))
  (setq rotation (mcp-json-get-number params "rotation"))
  (if (not scale) (setq scale 1.0))
  (if (not rotation) (setq rotation 0.0))
  (if (tblsearch "BLOCK" name)
    (progn
      ;; Insert with ATTREQ=1 to fill attributes
      (command "_.INSERT" name (list x y 0.0) scale scale rotation)
      ;; Note: attribute values are applied separately via update-attribute
      (cons T (strcat "{\"entity_type\":\"INSERT\",\"handle\":\"" (cdr (assoc 5 (entget (entlast)))) "\"}")))
    (cons nil (strcat "Block '" name "' not found"))
  )
)

(defun mcp-cmd-block-get-attributes (params / entity-id ent sub-ent ent-data attribs)
  (setq entity-id (mcp-json-get-string params "entity_id"))
  (if (= entity-id "last") (setq ent (entlast)) (setq ent (handent entity-id)))
  (if (not ent)
    (cons nil "Entity not found")
    (progn
      (setq attribs "" sub-ent (entnext ent))
      (while sub-ent
        (setq ent-data (entget sub-ent))
        (if (= (cdr (assoc 0 ent-data)) "ATTRIB")
          (progn
            (if (> (strlen attribs) 0) (setq attribs (strcat attribs ",")))
            (setq attribs (strcat attribs "\"" (cdr (assoc 2 ent-data)) "\":\"" (mcp-escape-string (cdr (assoc 1 ent-data))) "\""))
          )
        )
        (if (= (cdr (assoc 0 ent-data)) "SEQEND")
          (setq sub-ent nil)
          (setq sub-ent (entnext sub-ent))
        )
      )
      (cons T (strcat "{\"attributes\":{" attribs "}}"))
    )
  )
)

(defun mcp-cmd-block-update-attribute (params / entity-id tag value ent)
  (setq entity-id (mcp-json-get-string params "entity_id"))
  (setq tag (mcp-json-get-string params "tag"))
  (setq value (mcp-json-get-string params "value"))
  (if (= entity-id "last") (setq ent (entlast)) (setq ent (handent entity-id)))
  (if (not ent)
    (cons nil "Entity not found")
    (progn
      (if c:update-block-attribute
        (progn (c:update-block-attribute ent tag value)
               (cons T (strcat "{\"tag\":\"" tag "\",\"value\":\"" (mcp-escape-string value) "\"}")))
        ;; Inline fallback if attribute_tools.lsp not loaded
        (progn
          (set_attribute_value ent tag value)
          (cons T (strcat "{\"tag\":\"" tag "\",\"value\":\"" (mcp-escape-string value) "\"}")))
      )
    )
  )
)

(defun mcp-cmd-block-list (params-json / blk block-list)
  (setq block-list "" blk (tblnext "BLOCK" T))
  (while blk
    (if (not (= (substr (cdr (assoc 2 blk)) 1 1) "*"))
      (progn
        (if (> (strlen block-list) 0)
          (setq block-list (strcat block-list ",\"" (cdr (assoc 2 blk)) "\""))
          (setq block-list (strcat "\"" (cdr (assoc 2 blk)) "\""))
        )
      )
    )
    (setq blk (tblnext "BLOCK"))
  )
  (cons T (strcat "{\"blocks\":[" block-list "]}"))
)

(defun mcp-cmd-block-insert (params / name x y scale rotation block-id)
  (setq name (mcp-json-get-string params "name"))
  (setq x (mcp-json-get-number params "x"))
  (setq y (mcp-json-get-number params "y"))
  (setq scale (mcp-json-get-number params "scale"))
  (setq rotation (mcp-json-get-number params "rotation"))
  (setq block-id (mcp-json-get-string params "block_id"))
  (if (not scale) (setq scale 1.0))
  (if (not rotation) (setq rotation 0.0))
  (if (tblsearch "BLOCK" name)
    (progn
      (command "_.INSERT" name (list x y 0.0) scale scale rotation)
      (if (and block-id (> (strlen block-id) 0))
        (set_attribute_value (entlast) "ID" block-id)
      )
      (cons T (strcat "{\"entity_type\":\"INSERT\",\"handle\":\"" (cdr (assoc 5 (entget (entlast)))) "\"}"))
    )
    (cons nil (strcat "Block '" name "' not found"))
  )
)

(defun mcp-cmd-block-define (params-json)
  (cons nil "block-define not available via IPC (use ezdxf backend)")
)

;; --- command registration ---

(mcp-register "block-define" 'mcp-cmd-block-define)
(mcp-register "block-extract" 'mcp-cmd-block-extract)
(mcp-register "block-get-attributes" 'mcp-cmd-block-get-attributes)
(mcp-register "block-insert" 'mcp-cmd-block-insert)
(mcp-register "block-insert-with-attributes" 'mcp-cmd-block-insert-with-attribs)
(mcp-register "block-list" 'mcp-cmd-block-list)
(mcp-register "block-update-attribute" 'mcp-cmd-block-update-attribute)

(princ "\n  mcp_block loaded (7 commands)")
(princ)
