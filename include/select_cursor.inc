; Copyright (c) 2026 Stanislav Saveliev and CybouDB Contributors
; SPDX-License-Identifier: Apache-2.0
; Shared pull SELECT core. No allocation, callback, or public ABI dependency.
%ifndef CybouDB_SELECT_CURSOR_INC
%define CybouDB_SELECT_CURSOR_INC
%define SEL_DB          0
%define SEL_PLAN        8
%define SEL_BATCH       16
%define SEL_DECODE      24
%define SEL_SCAN        32              ; CybouDB_SCAN_SIZE bytes; every
                                        ; field below it follows that size
%define SEL_SCHEMA      120
%define SEL_LEAF_END    128
%define SEL_DECISION    136
%define SEL_PROJECTION  144
%define SEL_REQUIRED    152
%define SEL_LEAF_INDEX  160
%define SEL_SCHEMA_ID   168
%define SEL_COUNT       176
%define SEL_DONE        184
%define SEL_ERROR       192
%define SEL_OPTIONS     200             ; PAX_SCANOPT_SIZE private bytes
%define SEL_ENCODING_VIEWS (SEL_OPTIONS + PAX_SCANOPT_SIZE) ; zero when predicates use typed values
%define SEL_LIMIT_SKIP  (SEL_ENCODING_VIEWS + 48)
%define SEL_LIMIT_LEFT  (SEL_LIMIT_SKIP + 8)
; Set when the cursor was put where an index said the row is. It delivers
; that one batch and then reports the scan finished: the tree named one row
; and the predicate has just been evaluated over the batch holding it.
%define SEL_LOOKUP      (SEL_LIMIT_LEFT + 8)
%define SEL_LOOKUP_KEY  (SEL_LOOKUP + 8)     ; the key the plan is after
; The row the walk has read but this batch will not deliver: -2 means pull
; the next one, -1 means the walk is finished.
%define SEL_LOOKUP_ROW  (SEL_LOOKUP_KEY + 8)
%define SEL_ITER        (SEL_LOOKUP_ROW + 8) ; IDX_ITER_SIZE bytes
%define SQL_SELECT_SIZE (SEL_ITER + IDX_ITER_SIZE)
%endif
