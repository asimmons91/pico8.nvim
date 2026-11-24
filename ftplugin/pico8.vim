" PICO-8 carts use Lua-style comments.
if exists("b:did_ftplugin")
  finish
endif
let b:did_ftplugin = 1

setlocal commentstring=--\ %s
setlocal comments=:---,:--,://

let b:undo_ftplugin = "setlocal commentstring< comments<"

" PICO-8 include navigation. `gf` resolves targets relative to the cart (or a
" decoded PNG cart's source directory) through lua/pico_lsp/includes.lua; no
" helper setup is required. Only fill in an empty value, so a user's setting
" always wins. `include` is global-local: a global value is treated as a default
" and is overridden buffer-locally, then restored by the undo hook.
" `includeexpr` is local to the buffer, so a non-empty value is a user value and
" is left untouched.
if &l:include == ""
  let &l:include = '^\s*#include\s\+'
  let b:undo_ftplugin .= "|setlocal include<"
endif
if &l:includeexpr == ""
  let &l:includeexpr = 'v:lua.require("pico_lsp.includes").includeexpr(v:fname)'
  let b:undo_ftplugin .= "|setlocal includeexpr<"
endif

" Scope gf's unmodified-name lookup to the cart. Vim tries 'path' before
" 'includeexpr'; leaving the default ".,," lets a same-named file in the working
" directory win over a missing cart include. A decoded PNG virtual buffer gets
" its source directory from b:pico8_cart_root.
if &path == "" || &path == ".,,"
  let s:pico8_cart_dir = get(b:, "pico8_cart_root", "")
  if s:pico8_cart_dir == ""
    let s:pico8_cart_dir = expand("%:p:h")
  endif
  let s:pico8_path = v:lua.require("pico_lsp.includes").path_value(s:pico8_cart_dir)
  if s:pico8_path != ""
    let &l:path = s:pico8_path
    let b:pico8_path_scoped = 1
    let b:pico8_path_value = &l:path
    let b:undo_ftplugin .= "|setlocal path<|unlet! b:pico8_path_scoped b:pico8_path_value"
  endif
  unlet s:pico8_cart_dir s:pico8_path
endif

" Optional PICO-8 editor-style glyph shortcuts. Set g:pico8_glyph_maps = 1
" before opening a cart. In Lua code sections (but not #include paths),
" Shift-A..Z insert the 26 typeable P8SCII symbols (0x80-0x99) in alphabetical
" order, matching the PICO-8 editor. The mappings fetch canonical text from
" pico8/glyphs and fall back to the literal uppercase key outside code, in
" include paths, or without a client. Use CTRL-V u<hex> inside code to insert
" a literal uppercase letter, for example CTRL-V u0055 for U.
if get(g:, "pico8_glyph_maps", 0)
  let b:pico8_glyph_bufnr = str2nr(expand("<abuf>"))
  if b:pico8_glyph_bufnr == 0
    let b:pico8_glyph_bufnr = bufnr("%")
  endif
  execute "silent! lua require('pico_lsp').install_glyph_maps(" . b:pico8_glyph_bufnr . ")"
  for s:code in range(char2nr("A"), char2nr("Z"))
    let b:undo_ftplugin .= "|silent! iunmap <buffer> " . nr2char(s:code)
  endfor
  let b:undo_ftplugin .= "|unlet! b:pico8_glyph_bufnr"
  unlet s:code
endif
