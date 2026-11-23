; Based on tree-sitter-lua queries by Munif Tanjim (MIT).
; Cart structure
(cartridge_header) @preproc
(version_line) @keyword
(lua_section_header) @keyword.directive
(section_header) @keyword.directive
(section_payload) @string.special
(tab_marker) @comment
(include_directive) @preproc

; Comments
(comment) @comment
(comment) @spell

; Keywords
"return" @keyword.return
(break_statement) @keyword

[
  "do"
  "else"
  "elseif"
  "end"
  "for"
  "function"
  "goto"
  "if"
  "in"
  "local"
  "repeat"
  "then"
  "until"
  "while"
] @keyword

(if_statement
  [
    "if"
    "elseif"
    "else"
    "then"
    "end"
  ] @conditional)
(shorthand_if_statement
  [
    "if"
    "else"
  ] @conditional)
(elseif_statement
  [
    "elseif"
    "then"
  ] @conditional)
(else_statement
  [
    "else"
    "end"
  ] @conditional)
(while_statement
  [
    "while"
    "do"
    "end"
  ] @repeat)
(shorthand_while_statement "while" @repeat)
(repeat_statement
  [
    "repeat"
    "until"
  ] @repeat)
(for_statement
  [
    "for"
    "do"
    "end"
  ] @repeat)
(function_declaration
  [
    "function"
    "end"
  ] @keyword.function)
(function_definition
  [
    "function"
    "end"
  ] @keyword.function)
(do_statement
  [
    "do"
    "end"
  ] @keyword)

[
  "and"
  "not"
  "or"
] @keyword.operator

; PICO-8 shorthand and directives
(print_statement "?" @keyword)

; Operators
(binary_expression operator: _ @operator)
(unary_expression operator: _ @operator)
(assignment_statement operator: _ @operator)
"=" @operator

; Punctuation
[
  ";"
  ":"
  ","
  "."
] @punctuation.delimiter

[
  "("
  ")"
  "["
  "]"
  "{"
  "}"
] @punctuation.bracket

; Variables and constants
(identifier) @variable

((identifier) @variable.builtin
  (#eq? @variable.builtin "self"))

(variable_list
  (attribute
    "<" @punctuation.bracket
    (identifier) @attribute
    ">" @punctuation.bracket))

((identifier) @constant
  (#match? @constant "^[A-Z][A-Z_0-9]*$"))

(vararg_expression) @constant
(nil) @constant.builtin
[(false) (true)] @boolean

; Tables
(field name: (identifier) @field)
(dot_index_expression field: (identifier) @field)
(table_constructor "{" @constructor)

; Functions
(parameters (identifier) @parameter)

(function_declaration
  name: [
    (identifier) @function
    (dot_index_expression field: (identifier) @function)
  ])

(function_declaration
  name: (method_index_expression method: (identifier) @method))

(assignment_statement
  (variable_list
    .
    name: [
      (identifier) @function
      (dot_index_expression field: (identifier) @function)
    ])
  (expression_list
    .
    value: (function_definition)))

(table_constructor
  (field
    name: (identifier) @function
    value: (function_definition)))

(function_call
  name: [
    (identifier) @function.call
    (dot_index_expression field: (identifier) @function.call)
    (method_index_expression method: (identifier) @method.call)
  ])

; Strings, escapes, numbers
(string) @string
(escape_sequence) @string.escape
(number) @number
