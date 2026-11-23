pico-8 cartridge // pico-8.com
version 42
__lua__
-- pico-lsp smoke-test cart
-- Exercises tabs, comments, and UTF-16 position mapping.
-- Open this file in Neovim or Helix while testing M0.

function _init()
 x=64
 y=64
 speed=1
end

function _update()
 if (btn(➡️)) x+=speed
 if (btn(⬅️)) x-=speed
 if (btn(⬆️)) y-=speed
 if (btn(⬇️)) y+=speed
end

function _draw()
 cls(1)
 circfill(x,y,4,10)
 print("pico-lsp",2,2,7)
end
__gfx__
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
