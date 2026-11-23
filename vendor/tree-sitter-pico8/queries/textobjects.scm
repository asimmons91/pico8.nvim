(function_declaration) @function.outer
(function_declaration body: (block) @function.inner)
(function_definition) @function.outer
(function_definition body: (block) @function.inner)
(parameters (identifier) @parameter.inner)
(if_statement) @conditional.outer
(if_statement consequence: (block) @conditional.inner)
(elseif_statement consequence: (block) @conditional.inner)
(else_statement body: (block) @conditional.inner)
(while_statement) @loop.outer
(for_statement) @loop.outer
(repeat_statement) @loop.outer
(comment) @comment.outer
