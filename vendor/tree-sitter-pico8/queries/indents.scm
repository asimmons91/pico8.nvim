; Structural indentation. Helix and Neovim both understand these captures.

(function_declaration
  "function" @indent.begin
  "end" @indent.end)

(function_definition
  "function" @indent.begin
  "end" @indent.end)

(if_statement
  "if" @indent.begin
  "end" @indent.end)

(elseif_statement "elseif" @indent.branch)
(else_statement "else" @indent.branch)

(for_statement
  "for" @indent.begin
  "do" @indent.begin
  "end" @indent.end)

(while_statement
  "while" @indent.begin
  "do" @indent.begin
  "end" @indent.end)

(repeat_statement
  "repeat" @indent.begin
  "until" @indent.end)

(do_statement
  "do" @indent.begin
  "end" @indent.end)

(table_constructor
  "{" @indent.begin
  "}" @indent.end)

(parameters
  "(" @indent.begin
  ")" @indent.end)

(arguments
  "(" @indent.begin
  ")" @indent.end)
