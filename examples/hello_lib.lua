-- Included by examples/hello.p8.
-- The helper attaches pico_lsp to this file and sets b:pico8_cart.

function move_circle(x, y)
 if btn(➡️) then x+=1 end
 if btn(⬅️) then x-=1 end
 if btn(⬆️) then y-=1 end
 if btn(⬇️) then y+=1 end
 return x,y
end
