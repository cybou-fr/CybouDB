%ifndef CybouDB_VECTOR_INC
%define CybouDB_VECTOR_INC

%define CybouDB_VECTOR_ABI_VERSION 1

; Input/output state shared by exact cosine and squared-L2 streaming top-K.
%define VTOPK_STRUCT_SIZE    0   ; uint32_t: sizeof(cyboudb_vector_topk)
%define VTOPK_ABI_VERSION    4   ; uint32_t: CybouDB_VECTOR_ABI_VERSION
%define VTOPK_QUERY          8   ; const float *
%define VTOPK_VECTORS       16   ; first vector byte
%define VTOPK_COUNT         24   ; number of candidate vectors
%define VTOPK_DIM           32   ; FLOAT32 lanes per vector
%define VTOPK_K             40   ; output capacity/requested result count
%define VTOPK_STRIDE        48   ; bytes between vector starts
%define VTOPK_OUT_IDS       56   ; uint64_t[k]
%define VTOPK_OUT_SCORES    64   ; float[k]
%define VTOPK_OUT_COUNT     72   ; written result count
%define VTOPK_CANDIDATES    80   ; optional uint64_t bitmap; NULL means all rows
%define VTOPK_EVAL_COUNT    88   ; number of vector distances actually evaluated
%define VTOPK_STATE_SIZE    96

%define VECTOR_OK          0
%define VECTOR_INVALID    -1
%define VECTOR_NONFINITE  -2
%define VECTOR_FULL       -3

; Caller-owned contiguous vector arena. Vector id is its zero-based slot.
%define VARENA_STRUCT_SIZE   0   ; uint32_t: sizeof(cyboudb_vector_arena)
%define VARENA_ABI_VERSION   4   ; uint32_t: CybouDB_VECTOR_ABI_VERSION
%define VARENA_BASE          8
%define VARENA_CAPACITY     16
%define VARENA_USED         24
%define VARENA_DIM          32
%define VARENA_STRIDE       40
%define VARENA_COUNT        48
%define VARENA_SIZE         56

%endif
