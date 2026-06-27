let SessionLoad = 1
let s:so_save = &g:so | let s:siso_save = &g:siso | setg so=0 siso=0 | setl so=-1 siso=-1
let v:this_session=expand("<sfile>:p")
doautoall SessionLoadPre
silent only
silent tabonly
cd ~/code/zoms
if expand('%') == '' && !&modified && line('$') <= 1 && getline(1) == ''
  let s:wipebuf = bufnr('%')
endif
let s:shortmess_save = &shortmess
set shortmess+=aoO
badd +1 ~/code/zoms
badd +19 src/chunks/chunk_store.zig
badd +28 noms/go/chunks/chunk_store.go
badd +1 src/hash/hash.zig
badd +8 myterminal
badd +21 build.zig
badd +796 ~/downloads/zig-x86_64-linux-0.16.0/lib/std/Build.zig
badd +8 src/hash/base32.zig
badd +5 term1
argglobal
%argdel
$argadd ~/code/zoms
set stal=2
tabnew +setlocal\ bufhidden=wipe
tabnew +setlocal\ bufhidden=wipe
tabrewind
edit src/chunks/chunk_store.zig
let s:save_splitbelow = &splitbelow
let s:save_splitright = &splitright
set splitbelow splitright
wincmd _ | wincmd |
vsplit
1wincmd h
wincmd w
let &splitbelow = s:save_splitbelow
let &splitright = s:save_splitright
wincmd t
let s:save_winminheight = &winminheight
let s:save_winminwidth = &winminwidth
set winminheight=0
set winheight=1
set winminwidth=0
set winwidth=1
exe 'vert 1resize ' . ((&columns * 106 + 93) / 187)
exe 'vert 2resize ' . ((&columns * 80 + 93) / 187)
argglobal
balt noms/go/chunks/chunk_store.go
setlocal foldmethod=manual
setlocal foldexpr=0
setlocal foldmarker={{{,}}}
setlocal foldignore=#
setlocal foldlevel=0
setlocal foldminlines=1
setlocal foldnestmax=20
setlocal foldenable
silent! normal! zE
let &fdl = &fdl
let s:l = 226 - ((33 * winheight(0) + 26) / 52)
if s:l < 1 | let s:l = 1 | endif
keepjumps exe s:l
normal! zt
keepjumps 226
normal! 064|
lcd ~/code/zoms
wincmd w
argglobal
if bufexists(fnamemodify("~/code/zoms/src/chunks/chunk_store.zig", ":p")) | buffer ~/code/zoms/src/chunks/chunk_store.zig | else | edit ~/code/zoms/src/chunks/chunk_store.zig | endif
if &buftype ==# 'terminal'
  silent file ~/code/zoms/src/chunks/chunk_store.zig
endif
balt ~/code/zoms/noms/go/chunks/chunk_store.go
setlocal foldmethod=manual
setlocal foldexpr=0
setlocal foldmarker={{{,}}}
setlocal foldignore=#
setlocal foldlevel=0
setlocal foldminlines=1
setlocal foldnestmax=20
setlocal foldenable
silent! normal! zE
let &fdl = &fdl
let s:l = 18 - ((17 * winheight(0) + 26) / 52)
if s:l < 1 | let s:l = 1 | endif
keepjumps exe s:l
normal! zt
keepjumps 18
normal! 0
lcd ~/code/zoms
wincmd w
exe 'vert 1resize ' . ((&columns * 106 + 93) / 187)
exe 'vert 2resize ' . ((&columns * 80 + 93) / 187)
tabnext
edit ~/code/zoms/src/hash/hash.zig
argglobal
balt ~/code/zoms/src/hash/base32.zig
setlocal foldmethod=manual
setlocal foldexpr=0
setlocal foldmarker={{{,}}}
setlocal foldignore=#
setlocal foldlevel=0
setlocal foldminlines=1
setlocal foldnestmax=20
setlocal foldenable
silent! normal! zE
let &fdl = &fdl
let s:l = 1 - ((0 * winheight(0) + 26) / 52)
if s:l < 1 | let s:l = 1 | endif
keepjumps exe s:l
normal! zt
keepjumps 1
normal! 018|
lcd ~/code/zoms
tabnext
argglobal
if bufexists(fnamemodify("~/code/zoms/term1", ":p")) | buffer ~/code/zoms/term1 | else | edit ~/code/zoms/term1 | endif
if &buftype ==# 'terminal'
  silent file ~/code/zoms/term1
endif
setlocal foldmethod=manual
setlocal foldexpr=0
setlocal foldmarker={{{,}}}
setlocal foldignore=#
setlocal foldlevel=0
setlocal foldminlines=1
setlocal foldnestmax=20
setlocal nofoldenable
let s:l = 1 - ((0 * winheight(0) + 26) / 52)
if s:l < 1 | let s:l = 1 | endif
keepjumps exe s:l
normal! zt
keepjumps 1
normal! 033|
lcd ~/code/zoms
tabnext 1
set stal=1
if exists('s:wipebuf') && len(win_findbuf(s:wipebuf)) == 0 && getbufvar(s:wipebuf, '&buftype') isnot# 'terminal'
  silent exe 'bwipe ' . s:wipebuf
endif
unlet! s:wipebuf
set winheight=1 winwidth=20
let &shortmess = s:shortmess_save
let &winminheight = s:save_winminheight
let &winminwidth = s:save_winminwidth
let s:sx = expand("<sfile>:p:r")."x.vim"
if filereadable(s:sx)
  exe "source " . fnameescape(s:sx)
endif
let &g:so = s:so_save | let &g:siso = s:siso_save
set hlsearch
nohlsearch
doautoall SessionLoadPost
unlet SessionLoad
" vim: set ft=vim :
