%ifndef CybouDB_VECTOR_INC
%define CybouDB_VECTOR_INC

; Input/output state shared by exact cosine and squared-L2 streaming top-K.
%define VTOPK_QUERY       0   ; const float *
%define VTOPK_VECTORS     8   ; first vector byte
%define VTOPK_COUNT      16   ; number of candidate vectors
%define VTOPK_DIM        24   ; FLOAT32 lanes per vector
%define VTOPK_K          32   ; output capacity/requested result count
%define VTOPK_STRIDE     40   ; bytes between vector starts
%define VTOPK_OUT_IDS    48   ; uint64_t[k]
%define VTOPK_OUT_SCORES 56   ; float[k]
%define VTOPK_OUT_COUNT  64   ; written result count
%define VTOPK_CANDIDATES  72   ; optional uint64_t bitmap; NULL means all rows
%define VTOPK_EVAL_COUNT  80   ; number of vector distances actually evaluated
%define VTOPK_STATE_SIZE 88

%define VECTOR_OK          0
%define VECTOR_INVALID    -1
%define VECTOR_NONFINITE  -2
%define VECTOR_FULL       -3

; Caller-owned contiguous vector arena. Vector id is its zero-based slot.
%define VARENA_BASE       0
%define VARENA_CAPACITY   8
%define VARENA_USED      16
%define VARENA_DIM       24
%define VARENA_STRIDE    32
%define VARENA_COUNT     40
%define VARENA_SIZE      48

%endif
