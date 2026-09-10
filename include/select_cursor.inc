; Shared pull SELECT core. No allocation, callback, or public ABI dependency.
%ifndef CybouDB_SELECT_CURSOR_INC
%define CybouDB_SELECT_CURSOR_INC
%define SEL_DB          0
%define SEL_PLAN        8
%define SEL_BATCH       16
%define SEL_DECODE      24
%define SEL_SCAN        32              ; CybouDB_SCAN_SIZE bytes
%define SEL_SCHEMA      112
%define SEL_LEAF_END    120
%define SEL_DECISION    128
%define SEL_PROJECTION  136
%define SEL_REQUIRED    144
%define SEL_LEAF_INDEX  152
%define SEL_SCHEMA_ID   160
%define SEL_COUNT       168
%define SEL_DONE        176
%define SEL_ERROR       184
%define SEL_OPTIONS     192             ; PAX_SCANOPT_SIZE private bytes
%define SEL_ENCODING_VIEWS (SEL_OPTIONS + PAX_SCANOPT_SIZE) ; zero when predicates use typed values
%define SEL_LIMIT_SKIP  (SEL_ENCODING_VIEWS + 48)
%define SEL_LIMIT_LEFT  (SEL_LIMIT_SKIP + 8)
%define SQL_SELECT_SIZE (SEL_LIMIT_LEFT + 8)
%endif
