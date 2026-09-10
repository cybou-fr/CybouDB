%ifndef CYBOUDB_JOIN_CURSOR_INC
%define CYBOUDB_JOIN_CURSOR_INC

; Joined batches expose compact projection-ordinal column views. Each backing
; slot reserves the maximum scalar width for 64 rows.
%define JOIN_VALUE_STRIDE       (64 * 8)
%define JOIN_MAX_VALUE_BYTES    (64 * JOIN_VALUE_STRIDE)

%endif
