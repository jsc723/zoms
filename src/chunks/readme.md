zig build -Doptimize=ReleaseFast
cp zig-out/lib/libzjs.a noms/go/nbs/zjs/lib/
cp zig-out/include/zjs.h noms/go/nbs/zjs/lib/


rm -f ./codec-perf-rig && go build .
rm -rf /tmp/test-nbs && ./codec-perf-rig --db nbs::/tmp/test-nbs
rm -rf /tmp/test-zjs && ./codec-perf-rig --db zjs::/tmp/test-zjs

=== multi thread ===

ubuntu24@jsc-legion:~/code/zoms/noms/go/perf/codec-perf-rig$ rm -rf /tmp/test-zjs && ./codec-perf-rig --db zjs::/tmp/test-zjs
Codec perf: sepc=zjs::/tmp/test-zjs
Testing List:           build 100000  scan 100000                     insert 100000
numbers (8 B)           32 ms (24.43 MB/s)  18 ms (42.87 MB/s)              28 ms (28.49 MB/s)
strings (32 B)          55 ms (57.51 MB/s)  15 ms (212.47 MB/s)             72 ms (43.96 MB/s)
structs (64 B)          224 ms (28.55 MB/s)  39 ms (163.98 MB/s)             178 ms (35.92 MB/s)

Testing Set:            build 100000  scan 100000                     insert 100000
numbers (8 B)           24 ms (32.42 MB/s)  17 ms (45.88 MB/s)              115 ms (6.92 MB/s)
strings (32 B)          38 ms (83.70 MB/s)  22 ms (144.18 MB/s)             141 ms (22.56 MB/s)
structs (64 B)          1330 ms (4.81 MB/s)  37 ms (168.46 MB/s)             1586 ms (4.03 MB/s)

Testing Map:            build 100000  scan 100000                     insert 100000
numbers (8 B)           44 ms (18.01 MB/s)  36 ms (21.76 MB/s)              174 ms (4.60 MB/s)
strings (32 B)          97 ms (32.71 MB/s)  31 ms (101.35 MB/s)             240 ms (13.29 MB/s)
structs (64 B)          1672 ms (3.83 MB/s)  71 ms (89.17 MB/s)              1748 ms (3.66 MB/s)

Testing Blob:           build 33 MB  scan 33 MB
                        278 ms (120.43 MB/s)  65 ms (514.08 MB/s)

ubuntu24@jsc-legion:~/code/zoms/noms/go/perf/codec-perf-rig$ rm -rf /tmp/test-nbs && ./codec-perf-rig --db nbs::/tmp/test-nbs
Codec perf: sepc=nbs::/tmp/test-nbs
Testing List:           build 100000  scan 100000                     insert 100000
numbers (8 B)           23 ms (33.81 MB/s)  17 ms (45.77 MB/s)              27 ms (28.70 MB/s)
strings (32 B)          50 ms (63.73 MB/s)  13 ms (237.87 MB/s)             63 ms (50.79 MB/s)
structs (64 B)          198 ms (32.24 MB/s)  21 ms (298.18 MB/s)             129 ms (49.30 MB/s)

Testing Set:            build 100000  scan 100000                     insert 100000
numbers (8 B)           22 ms (35.93 MB/s)  18 ms (43.28 MB/s)              142 ms (5.59 MB/s)
strings (32 B)          35 ms (89.82 MB/s)  17 ms (179.89 MB/s)             136 ms (23.48 MB/s)
structs (64 B)          1381 ms (4.63 MB/s)  33 ms (189.50 MB/s)             1566 ms (4.09 MB/s)

Testing Map:            build 100000  scan 100000                     insert 100000
numbers (8 B)           42 ms (18.62 MB/s)  34 ms (23.02 MB/s)              179 ms (4.44 MB/s)
strings (32 B)          98 ms (32.54 MB/s)  30 ms (106.24 MB/s)             229 ms (13.96 MB/s)
structs (64 B)          1641 ms (3.90 MB/s)  48 ms (132.72 MB/s)             1782 ms (3.59 MB/s)

Testing Blob:           build 33 MB  scan 33 MB
                        228 ms (146.84 MB/s)  25 ms (1318.71 MB/s)

=== single thread ===

ubuntu24@jsc-legion:~/code/zoms/noms/go/perf/codec-perf-rig$ rm -rf /tmp/test-nbs && GOMAXPROCS=1 ./codec-perf-rig 
--db nbs::/tmp/test-nbs
Codec perf: sepc=nbs::/tmp/test-nbs
Testing List:           build 100000                    scan 100000                     insert 100000
numbers (8 B)           27 ms (29.58 MB/s)              21 ms (36.97 MB/s)              34 ms (23.05 MB/s)
strings (32 B)          65 ms (49.16 MB/s)              21 ms (147.80 MB/s)             78 ms (40.85 MB/s)
structs (64 B)          214 ms (29.83 MB/s)             33 ms (193.75 MB/s)             179 ms (35.64 MB/s)

Testing Set:            build 100000                    scan 100000                     insert 100000
numbers (8 B)           23 ms (34.40 MB/s)              24 ms (32.03 MB/s)              112 ms (7.10 MB/s)
strings (32 B)          42 ms (75.95 MB/s)              26 ms (119.86 MB/s)             138 ms (23.15 MB/s)
structs (64 B)          1352 ms (4.73 MB/s)             39 ms (162.74 MB/s)             1499 ms (4.27 MB/s)

Testing Map:            build 100000                    scan 100000                     insert 100000
numbers (8 B)           50 ms (15.94 MB/s)              42 ms (18.75 MB/s)              156 ms (5.10 MB/s)
strings (32 B)          103 ms (30.99 MB/s)             39 ms (80.67 MB/s)              255 ms (12.54 MB/s)
structs (64 B)          1692 ms (3.78 MB/s)             76 ms (83.18 MB/s)              1704 ms (3.76 MB/s)

Testing Blob:           build 33 MB                     scan 33 MB
                        309 ms (108.42 MB/s)            56 ms (589.36 MB/s)


ubuntu24@jsc-legion:~/code/zoms/noms/go/perf/codec-perf-rig$ rm -rf /tmp/test-zjs && GOMAXPROCS=1 ./codec-perf-rig 
--db zjs::/tmp/test-zjs
Codec perf: sepc=zjs::/tmp/test-zjs
Testing List:           build 100000                    scan 100000                     insert 100000
numbers (8 B)           24 ms (32.72 MB/s)              20 ms (39.11 MB/s)              34 ms (23.49 MB/s)
strings (32 B)          70 ms (45.44 MB/s)              20 ms (156.33 MB/s)             79 ms (40.03 MB/s)
structs (64 B)          233 ms (27.39 MB/s)             47 ms (134.96 MB/s)             160 ms (39.84 MB/s)

Testing Set:            build 100000                    scan 100000                     insert 100000
numbers (8 B)           21 ms (37.91 MB/s)              18 ms (43.46 MB/s)              117 ms (6.83 MB/s)
strings (32 B)          41 ms (77.48 MB/s)              25 ms (126.39 MB/s)             138 ms (23.11 MB/s)
structs (64 B)          1469 ms (4.36 MB/s)             43 ms (148.01 MB/s)             1524 ms (4.20 MB/s)

Testing Map:            build 100000                    scan 100000                     insert 100000
numbers (8 B)           39 ms (20.05 MB/s)              37 ms (21.27 MB/s)              166 ms (4.80 MB/s)
strings (32 B)          103 ms (30.92 MB/s)             41 ms (77.45 MB/s)              260 ms (12.30 MB/s)
structs (64 B)          1698 ms (3.77 MB/s)             80 ms (79.90 MB/s)              1774 ms (3.61 MB/s)

Testing Blob:           build 33 MB                     scan 33 MB
                        335 ms (100.12 MB/s)            38 ms (872.57 MB/s)