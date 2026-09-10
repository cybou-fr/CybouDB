; =============================================================================
;  constants.inc - Engine-wide CybouDB constants
; =============================================================================
;  Only things that depend on neither the CPU architecture nor the OS:
;  the format signature, the version, core error codes and process exit codes.
; =============================================================================

%ifndef CybouDB_CONSTANTS_INC
%define CybouDB_CONSTANTS_INC

; --- Format identification ---------------------------------------------------
%define CybouDB_MAGIC        0x4C515341    ; 'A','S','Q','L' in little-endian order
%define CybouDB_VERSION      1

; --- Core error codes --------------------------------------------------------
;  Returned in RAX by the db_* functions. Zero means success, anything else
;  is a failure. The values double as an index into the CLI message table,
;  so they must stay consecutive and gap-free.
%define CybouDB_OK           0
%define CybouDB_E_PAGES      1             ; invalid page count
%define CybouDB_E_CREATE     2             ; cannot create the file
%define CybouDB_E_OPEN       3             ; cannot open the file
%define CybouDB_E_SIZE       4             ; cannot query the file size
%define CybouDB_E_SMALL      5             ; file smaller than the metadata pages
%define CybouDB_E_MAP        6             ; memory mapping failed
%define CybouDB_E_MAGIC      7             ; foreign signature
%define CybouDB_E_VERSION    8             ; unsupported format version
%define CybouDB_E_PAGESIZE   9             ; unsupported page size
%define CybouDB_E_HDR_CRC    10            ; file header checksum mismatch
%define CybouDB_E_FEATURES   11            ; unknown incompatible feature bits
%define CybouDB_E_SUPERBLOCK 12            ; no superblock copy verifies
%define CybouDB_E_GEOMETRY   13            ; page counts disagree with the file
%define CybouDB_E_EXISTS     14            ; refusing to overwrite an existing file
%define CybouDB_E_FULL       15            ; no page left to hand out
%define CybouDB_E_FREELIST   16            ; the free list is corrupt
%define CybouDB_E_PAGE       17            ; page id outside the allocatable range
%define CybouDB_E_READONLY   18            ; the database was opened read-only
%define CybouDB_E_SYNC       19            ; the commit could not reach the disk
%define CybouDB_E_NOENT      20            ; the path does not exist
%define CybouDB_E_ACCESS     21            ; the OS refused permission
%define CybouDB_E_STATE      22            ; invalid mutation mode or failed handle
%define CybouDB_E_GENERATION 23            ; generation counter exhausted
%define CybouDB_E_BITMAP     24            ; staged allocation state is inconsistent
%define CybouDB_E_COW_PAGES  25            ; outside the single-map capacity
%define CybouDB_E_CATALOG    26            ; invalid catalog graph
%define CybouDB_E_SCHEMA     27            ; invalid schema or duplicate table name
%define CybouDB_E_NOTFOUND   28            ; table id absent from catalog
%define CybouDB_E_CATALOG_FULL 29          ; directory capacity reached
%define CybouDB_E_ROWS       30            ; invalid batch count or row index
%define CybouDB_E_PAX        31            ; invalid PAX data page
%define CybouDB_E_VALUE      32            ; invalid scalar value or NULL constraint
%define CybouDB_E_COUNT      33            ; size of the message table

; --- Why an operating system call failed -------------------------------------
;  The platform layer translates its native error - errno on Linux, the Win32
;  error code on Windows - into one of these before handing it up. Core code
;  must never see a raw errno: the numbers differ between systems, and mapping
;  them in core/ would put OS knowledge exactly where it does not belong.
;
;  Everything not worth distinguishing collapses into OTHER on purpose. These
;  four are the ones a caller can actually do something about.
%define CybouDB_OSERR_NONE   0
%define CybouDB_OSERR_NOENT  1             ; no such file or directory
%define CybouDB_OSERR_ACCESS 2             ; permission denied
%define CybouDB_OSERR_EXISTS 3             ; the path is already taken
%define CybouDB_OSERR_OTHER  4

; --- Process exit codes ------------------------------------------------------
%define EXIT_OK           0
%define EXIT_USAGE        1
%define EXIT_FAILURE      2

%endif ; CybouDB_CONSTANTS_INC
