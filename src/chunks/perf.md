zig build -Doptimize=ReleaseFast
cp zig-out/lib/libzjs.a noms/go/nbs/zjs/lib/
cp zig-out/include/zjs.h noms/go/nbs/zjs/lib/


rm -f ./codec-perf-rig && go build .
rm -rf /tmp/test-nbs && ./codec-perf-rig --db nbs:/tmp/test-nbs
rm -rf /tmp/test-zjs && ./codec-perf-rig --db zjs:/tmp/test-zjs
ubuntu24@jsc-legion:~/code/zoms/noms/go/perf/codec-perf-rig$ rm -rf /tmp/test-zjs && ./codec-perf-rig --db zjs:/tm
p/test-zjs
Codec perf: sepc=zjs:/tmp/test-zjs
Testing List:           build 100000                    scan 100000                     insert 100000
numbers (8 B)           25 ms (30.86 MB/s)              22 ms (35.62 MB/s)              36 ms (22.07 MB/s)
strings (32 B)          57 ms (55.33 MB/s)              14 ms (223.08 MB/s)             65 ms (48.66 MB/s)
structs (64 B)          219 ms (29.17 MB/s)             37 ms (169.38 MB/s)             162 ms (39.48 MB/s)

Testing Set:            build 100000                    scan 100000                     insert 100000
numbers (8 B)           20 ms (39.91 MB/s)              17 ms (46.48 MB/s)              110 ms (7.27 MB/s)
strings (32 B)          35 ms (89.39 MB/s)              22 ms (145.45 MB/s)             136 ms (23.46 MB/s)
structs (64 B)          1436 ms (4.46 MB/s)             41 ms (153.97 MB/s)             1584 ms (4.04 MB/s)

Testing Map:            build 100000                    scan 100000                     insert 100000
numbers (8 B)           42 ms (18.64 MB/s)              41 ms (19.23 MB/s)              165 ms (4.82 MB/s)
strings (32 B)          105 ms (30.30 MB/s)             32 ms (97.82 MB/s)              229 ms (13.94 MB/s)
structs (64 B)          1718 ms (3.72 MB/s)             75 ms (85.15 MB/s)              1731 ms (3.70 MB/s)

Testing Blob:           build 33 MB                     scan 33 MB
                        281 ms (119.13 MB/s)            34 ms (962.46 MB/s)

ubuntu24@jsc-legion:~/code/zoms/noms/go/perf/codec-perf-rig$ rm -rf /tmp/test-nbs && ./codec-perf-rig --db nbs:/tm
p/test-nbs
Codec perf: sepc=nbs:/tmp/test-nbs
Testing List:           build 100000                    scan 100000                     insert 100000
numbers (8 B)           33 ms (23.70 MB/s)              20 ms (38.95 MB/s)              26 ms (30.00 MB/s)
strings (32 B)          45 ms (70.81 MB/s)              13 ms (233.77 MB/s)             60 ms (53.21 MB/s)
structs (64 B)          207 ms (30.83 MB/s)             25 ms (252.46 MB/s)             139 ms (45.85 MB/s)

Testing Set:            build 100000                    scan 100000                     insert 100000
numbers (8 B)           17 ms (45.40 MB/s)              15 ms (51.15 MB/s)              111 ms (7.20 MB/s)
strings (32 B)          32 ms (98.74 MB/s)              17 ms (187.28 MB/s)             145 ms (22.06 MB/s)
structs (64 B)          1260 ms (5.08 MB/s)             21 ms (298.26 MB/s)             1488 ms (4.30 MB/s)

Testing Map:            build 100000                    scan 100000                     insert 100000
numbers (8 B)           36 ms (21.87 MB/s)              30 ms (26.04 MB/s)              150 ms (5.32 MB/s)
strings (32 B)          85 ms (37.46 MB/s)              27 ms (117.38 MB/s)             222 ms (14.41 MB/s)
structs (64 B)          1581 ms (4.05 MB/s)             43 ms (145.56 MB/s)             1665 ms (3.84 MB/s)

Testing Blob:           build 33 MB                     scan 33 MB
                        251 ms (133.17 MB/s)            20 ms (1653.00 MB/s)