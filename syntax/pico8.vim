" Vim syntax file for PICO-8 text carts.
" Install by adding this plugin to 'runtimepath' or copy this file to
" ~/.config/nvim/syntax/pico8.vim.

if exists("b:current_syntax")
  finish
endif

syn case ignore

" Sections and tab markers.
syn match pico8Section /^__\(lua\|gfx\|gff\|label\|map\|sfx\|music\)__\s*$/
syn match pico8Tab /^-->8.*$/
syn match pico8Include /^\s*#include\b.*$/

" Comments.
syn region pico8Comment start="--\[\[" end="\]\]" keepend
syn match pico8Comment /--.*$/
syn match pico8Comment /\/\/.*$/

" Strings.
syn region pico8String start=/"/ skip=/\\"/ end=/"/
syn region pico8String start=/'/ skip=/\\'/ end=/'/
syn region pico8LongString start="\[\[" end="\]\]" keepend

" Numbers and identifiers.
syn match pico8Number /\<0x[0-9a-f]\+\>/
syn match pico8Number /\<0b[01]\+\>/
syn match pico8Number /\<[0-9]\+\(\.[0-9]\+\)\?\>/

" Dialect keywords.
syn keyword pico8Keyword if then else elseif end for while repeat until do
syn keyword pico8Keyword local function return break goto in and or not
syn keyword pico8Boolean true false nil
syn keyword pico8Self self
syn match pico8Shorthand /^\s*[?]/

" Operators, including PICO-8 peek operators and integer division.
syn match pico8Operator /[+\-*/%\\^#=<>~&|]\+/
syn match pico8Operator /[@$]/
syn match pico8Punctuation /[][{}:;,.()]/

hi def link pico8Section PreProc
hi def link pico8Tab PreProc
hi def link pico8Include PreProc
hi def link pico8Comment Comment
hi def link pico8String String
hi def link pico8LongString String
hi def link pico8Number Number
hi def link pico8Keyword Keyword
hi def link pico8Boolean Boolean
hi def link pico8Self Special
hi def link pico8Shorthand Statement
hi def link pico8Operator Operator
hi def link pico8Punctuation Delimiter

let b:current_syntax = "pico8"
