; =============================================================================
;  format.inc - On-disk binary format of an CybouDB database file, version 1
; =============================================================================
;  The format is architecture-neutral by construction: every numeric field is
;  little-endian, every size is fixed, and every 64-bit field is aligned to 8
;  bytes so that a future implementation may use atomics on it. A database
;  created on x86-64 is readable on AArch64 without conversion.
;
;  The file is split into two kinds of metadata, and the split is deliberate:
;
;    page 0        FILE HEADER - immutable identity and geometry of the file.
;                  Written once by db_create and never rewritten afterwards.
;
;    pages 1 and 2 SUPERBLOCK, two copies - everything that changes as the
;                  database is used: page counts, free list, future root
;                  pointers. Each copy carries a generation number and its
;                  own checksum. A commit writes the copy that is NOT
;                  currently newest, then that copy becomes newest by virtue
;                  of its higher generation.
;
;  Keeping mutable state out of the header is what makes crash recovery
;  possible at all: whatever happens during a commit, the previous generation
;  survives intact in the other copy, and the reader simply picks the
;  highest-generation copy whose checksum verifies.
;
;  The commit protocol that uses this layout lives in db_commit: flush the
;  data pages, write the copy that is not live with generation + 1, flush
;  again, then adopt it. A crash between the two flushes leaves a half-written
;  copy that fails its checksum, and the reader falls back to the previous
;  generation.
;
;  NOTE ON DURABILITY: this is single-writer only. Nothing here coordinates
;  two processes writing the same file at once, and no lock is taken, so
;  concurrent writers are still undefined behaviour.
; =============================================================================

%ifndef CybouDB_FORMAT_INC
%define CybouDB_FORMAT_INC

%include "constants.inc"
%include "page.inc"

; =============================================================================
;  FILE HEADER - page 0, 128 bytes defined, the rest of the page is zero
; =============================================================================
;  Offset  Size  Field            Description
;  ------  ----  ---------------  ---------------------------------------
;    +0      4   magic            'CybouDB' = 0x4C515341
;    +4      4   header_size      bytes of header actually defined (128)
;    +8      4   format_version   1
;   +12      4   page_size        logical page size in bytes (4096)
;   +16      8   flags_incompat   unknown bit set => refuse to open
;   +24      8   flags_compat     unknown bits may be ignored safely
;   +32      8   sb_page_a        page index of superblock copy A (1)
;   +40      8   sb_page_b        page index of superblock copy B (2)
;   +48     16   reserved_uuid    database identity, zero until implemented
;   +64     60   reserved         zero
;  +124      4   crc32c           CRC-32C over bytes [0, 124)
;  ------  ----
;   total   128
; =============================================================================

%define CybouDB_HDR_SIZE       128

%define HDR_MAGIC           0
%define HDR_HEADER_SIZE     4
%define HDR_VERSION         8
%define HDR_PAGE_SIZE       12
%define HDR_FLAGS_INCOMPAT  16
%define HDR_FLAGS_COMPAT    24
%define HDR_SB_PAGE_A       32
%define HDR_SB_PAGE_B       40
%define HDR_UUID            48
%define HDR_UUID_SIZE       16
%define HDR_RESERVED        64
%define HDR_RESERVED_SIZE   60
%define HDR_CRC             124

; Bytes covered by the header checksum: everything ahead of the field itself.
%define HDR_CRC_LEN         HDR_CRC

; Creation-time incompatible capability. Bit 0 remains unsupported.
%define CybouDB_FEATURE_COW    2
%define CybouDB_FEATURE_CATALOG 4          ; requires COW; root is a catalog tree
%define CybouDB_FEATURE_PAX_MULTI 16       ; PAX data-page directory
%define CybouDB_FEATURE_MAP_SPAN 32        ; requires COW; paired multi-page map
%define CybouDB_FEATURE_PAX    8           ; requires COW + catalog; schema data roots
; Multi-page PAX leaves - requires PAX. A leaf is a run of contiguous pages
; whose length comes from the schema, rather than always one 4 KiB page. A
; page cannot hold 64 rows of a wide schema at all, so without this a table of
; 32 INT32 columns stores 24 rows per leaf and one of 64 INT64 columns stores
; four. The bit is what tells pax_capacity which arithmetic a file was written
; with: validation compares a recomputed capacity against a stored one, so a
; changed formula would otherwise reject every existing database.
; See docs/PAX_CAPACITY.md.
%define CybouDB_FEATURE_PAX_RUNS 64
; Two-level PAX directories - requires PAX_MULTI. A table whose leaves outgrow
; one directory page grows a root directory of directory pages instead of
; stopping at 251 leaves. A table small enough not to need it stays flat, so
; the bit changes nothing until it is earned. See docs/PAX_MULTI.md.
%define CybouDB_FEATURE_PAX_TREE 128
; Per-leaf zone metadata - requires PAX. A table keeps min/max and NULL
; statistics for every leaf in a side structure hanging off CAT_STATS_ROOT, so
; a scan can skip or accept a whole leaf without reading its column pages. The
; PAX leaf format is unchanged; what changes is that a schema page may carry a
; statistics root where every earlier build validated a zero, which is why this
; is an incompatible bit rather than a hint. See docs/ZONEMAP.md.
%define CybouDB_FEATURE_ZONE_MAPS 256
; Per-column compression - requires PAX. Columns within a PAX leaf can be
; encoded with Frame-of-Reference (bitpacking) or Constant encodings.
; An uncompressed leaf remains bit-for-bit identical to v1.
%define CybouDB_FEATURE_COMPRESSION 512
; Variable-width TEXT/BLOB cell descriptors and owned extent chains. Reserved
; until the catalog graph validator follows every descriptor; creators do not
; emit this bit yet. See docs/VARLEN.md.
%define CybouDB_FEATURE_VARLEN 1024

; Column compression codecs (stored in bits 8..15 of leaf column flags):
%define PAX_CODEC_RAW       0
%define PAX_CODEC_CONST     1
%define PAX_CODEC_FOR       2

%define CybouDB_COW_MIN_PAGES  4
; One two-bit allocation map: bytes 64..4091, CRC at end of page.
%define CybouDB_MAP_MAGIC      0x424D5141    ; 'A','Q','M','B'
%define MAP_MAGIC           0
%define MAP_HEADER_SIZE     4
%define MAP_PAGE_ID         8
%define MAP_GENERATION      16
%define MAP_TOTAL           24
%define MAP_ALLOC           32
%define MAP_RESERVED        40
%define MAP_SPAN            40          ; span layout: first page this leaf covers
%define MAP_SPAN_RESERVED   48
%define MAP_DATA            64
%define MAP_CRC             4092
%define CybouDB_COW_MAX_PAGES  ((MAP_CRC - MAP_DATA) * 4)
%define MAP_FREE            0
%define MAP_PAYLOAD         1
%define MAP_METADATA        2
; Reclamation, span layout only: the page is not reachable from this
; generation, though the one before it may still hold a reference.
%define MAP_RETIRED         3

; -----------------------------------------------------------------------------
;  The span allocation map - CybouDB_FEATURE_MAP_SPAN
; -----------------------------------------------------------------------------
;  One map page covers CybouDB_COW_MAX_PAGES pages, which caps a flat-map file at
;  63 MiB. The span layout drops that cap by storing K = ceil(total pages /
;  CybouDB_MAP_LEAF_PAGES) consecutive map pages, twice, at fixed positions right
;  after the two superblocks:
;
;      page 0            file header
;      pages 1, 2        superblock A, B
;      pages 3 .. 3+K-1  allocation map copy A
;      pages 3+K .. 3+2K allocation map copy B
;      pages 3+2K ..     payload
;
;  Copy X belongs to whichever generation is published in superblock X, so the
;  map is metadata of the same class as the superblock rather than something
;  the allocator has to allocate. Leaf i of a copy is always that copy's first
;  page plus i, so there is no pointer structure to validate, nothing to leak
;  and no way for map growth to recurse into the allocator.
;
;  Leaf headers reuse the flat field offsets, except that a leaf is identified
;  by where it sits rather than by MAP_PAGE_ID, which stays zero so that an
;  unchanged leaf is byte-identical in both copies:
;
;    MAP_TOTAL    total pages in the file, in every leaf
;    MAP_ALLOC    the high-water mark, in leaf zero only, zero elsewhere
;    MAP_SPAN     first page id this leaf describes, i * CybouDB_MAP_LEAF_PAGES
;
;  A writer mutates the inactive copy and publishes it with the superblock. It
;  does not need its own barrier: a torn map fails its checksum, which rejects
;  that superblock candidate. The cost is that the older of the two recoverable
;  generations ends when a writer first allocates rather than at commit.
%define CybouDB_MAP_LEAF_PAGES CybouDB_COW_MAX_PAGES
%define CybouDB_MAP_MAX_LEAVES 1024
%define CybouDB_SPAN_MAX_PAGES (CybouDB_MAP_LEAF_PAGES * CybouDB_MAP_MAX_LEAVES)

; =============================================================================
;  SUPERBLOCK - pages 1 and 2, 128 bytes defined, the rest of the page is zero
; =============================================================================
;  Offset  Size  Field            Description
;  ------  ----  ---------------  ---------------------------------------
;    +0      4   magic            'ASQS' = 0x53515341
;    +4      4   sb_size          bytes of superblock actually defined (128)
;    +8      8   generation       increases on every commit; highest wins
;   +16      8   total_pages      pages in the file as of this generation
;   +24      8   allocated_pages  high-water mark, see the note below
;   +32      8   freelist_root    first free-list page, 0 when empty
;   +40      8   root_page        catalog root, 0 until the catalog exists
;   +48      8   bitmap_root      COW allocation map; reserved/zero in legacy
;   +56      8   feature_root     extension directory, 0 until one exists
;   +64     56   reserved         zero
;  +120      4   staged           in-memory marker, always zero on disk
;  +124      4   crc32c           CRC-32C over bytes [0, 124)
;  ------  ----
;   total   128
;
;  On feature_root: things a database grows later - authenticated page
;  encryption with its key slots and rotation state, vector index metadata -
;  do not belong in the immutable header, and they are too big and too
;  changeable to spell out as superblock fields. They get one copy-on-write
;  page id here instead, so the superblock keeps naming exactly three roots:
;  what is allocated, what the schema is, and what has been bolted on.
;
;  Nothing writes it yet, and a non-zero value is refused rather than ignored:
;  it can only mean an extension this build does not implement. The field is
;  defined now because adding it later would mean changing the size of the
;  superblock again, and that is the disruptive part.
; =============================================================================

%define CybouDB_SB_SIZE        128
%define CybouDB_SB_MAGIC       0x53515341    ; 'A','S','Q','S' little-endian

%define SB_MAGIC            0
%define SB_SIZE             4
%define SB_GENERATION       8
%define SB_TOTAL_PAGES      16
%define SB_ALLOC_PAGES      24
%define SB_FREELIST_ROOT    32
%define SB_ROOT_PAGE        40
%define SB_RESERVED         48
%define SB_BITMAP_ROOT      48          ; defined only with CybouDB_FEATURE_COW
%define SB_FEATURE_ROOT     56
%define SB_RESERVED_TAIL    64
%define SB_RESERVED_TAIL_SIZE 56
; Only ever set in the in-memory candidate a writer builds to check its own
; half-finished graph, never on disk: an on-disk superblock with this field
; set is rejected. A staged graph is rebuilt one page at a time, so between
; copying a page and relinking its parent the old page is already retired
; while the parent still names it. Marking the candidate as in progress lets
; the walk accept that; the commit builds a clean candidate and so applies the
; strict rule, which is where a reference left dangling is caught.
%define SB_STAGED           120
%define SB_CRC              124

%define SB_CRC_LEN          SB_CRC

; -----------------------------------------------------------------------------
;  What allocated_pages means
; -----------------------------------------------------------------------------
;  It is a high-water mark, not a count of pages currently in use: every page
;  below it has been claimed at least once. Freeing a page does not lower it -
;  the page joins the free list and is handed out again from there. That keeps
;  the invariant simple and always checkable against the file:
;
;      CybouDB_MIN_PAGES <= allocated_pages <= total_pages
;
;  and it means a page id never changes meaning once it has been issued.
; -----------------------------------------------------------------------------

; =============================================================================
;  FREE PAGE RECORD - the first 16 bytes of a page on the free list
; =============================================================================
;  Free pages are chained through themselves, so the free list costs no extra
;  storage: freelist_root in the superblock names the first one, and each free
;  page names the next. The magic lets a corrupt chain be detected instead of
;  silently handing out a page that is still in use.
;
;  Offset  Size  Field       Description
;  ------  ----  ----------  ---------------------------------------------
;    +0      4   magic       'ASQF' = 0x46515341
;    +4      4   reserved    zero
;    +8      8   next        next free page, 0 when this is the last one
; =============================================================================

%define CybouDB_FREE_MAGIC     0x46515341    ; 'A','S','Q','F' little-endian
%define CybouDB_FREE_SIZE      16

%define FREE_MAGIC          0
%define FREE_RESERVED       4
%define FREE_NEXT           8

; --- Fixed page assignments --------------------------------------------------
%define CybouDB_SB_PAGE_A      1
%define CybouDB_SB_PAGE_B      2

; Header page plus both superblock copies: the smallest legal database.
%define CybouDB_MIN_PAGES      3

%endif ; CybouDB_FORMAT_INC
