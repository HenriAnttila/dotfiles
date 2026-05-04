((call_expression
   function: (identifier) @_name
   arguments: (template_string (string_fragment) @injection.content))
 (#eq? @_name "gql")
 (#set! injection.language "graphql"))
