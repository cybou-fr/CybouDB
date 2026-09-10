; Two-level catalog, enabled only with CybouDB_FEATURE_CATALOG plus COW.
%ifndef CybouDB_CATALOG_INC
%define CybouDB_CATALOG_INC
%define CAT_MAGIC_VALUE 0x43515341       ; ASQC
%define CAT_VERSION_VALUE 1
%define CAT_MAGIC 0
%define CAT_VERSION 4
%define CAT_PAGE_ID 8
%define CAT_GENERATION 16
%define CAT_OWNER 24
%define CAT_TYPE 32
%define CAT_COUNT 36
%define CAT_RESERVED 40
%define CAT_DATA 64
%define CAT_CRC 4092
%define CAT_DIRECTORY 1
%define CAT_SCHEMA 2
%define CAT_MAX_TABLES 251
%define CAT_TABLE_NAME 64
%define CAT_COLUMNS 96
%define CAT_COLUMN_SIZE 32
%define CAT_MAX_COLUMNS 64
%define CAT_INT32 1
%define CAT_INT64 2
%define CAT_FLOAT32 3
%define CAT_BOOL 4
%define CAT_TEXT 5
%define CAT_BLOB 6
%define CAT_NULLABLE 1
%endif
