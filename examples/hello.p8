pico-8 cartridge // pico8.com
version 42
__lua__
-- pico8.nvim demo cart
-- The include below belongs to this cart.
-- pico_lsp also attaches to examples/hello_lib.lua.

#include hello_lib.lua

function _init()
 x=64
 y=64
end

function _update()
 x,y=move_circle(x,y)
end

function _draw()
 cls(1)
 circfill(x,y,4,10)
 print("hello pico8.nvim",2,2,7)
end

-->8
-- A second code tab gives :Pico8Tabs something to list.
function tab_two()
 print("tab two",2,12,6)
end
__gfx__
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
