@{%
  const moo = require('moo')
  const { utils } = require('ethers');
  function id(x) { return x[0]; }

  let lexer = moo.compile({
    space: { match: /\s+/, lineBreaks: true },
    singleLineComment: /\/\/.*?$/,
    multiComment: /\/\*[\s\S]*?\*\/|(?:[^\\:]|^)\/\/.*$/,
    NumberLiteral: /(?!0x)[0-9]+/,
    HexLiteral: /(?:hex)(?:"|')[0-9a-fA-F]+(?:"|')/,
    HexNumber: /0[x][0-9a-fA-F]+/,
    StringLiteral: /"(?:\\["bfnrt\/\\]|\\u[a-fA-F0-9]{4}|[^"\\])*"/,
    equate: ":=",
    "->": "->",
    ",": ",",
    SigLiteral: /(?:sig)(?:"|').*(?:"|')/,
    TopicLiteral: /(?:topic)(?:"|').*(?:"|')/,
    codeKeyword: /(?:code)(?:\s)/,
    objectKeyword: /(?:object)(?:\s)/,
    dataKeyword: /(?:data)(?:\s)/,
    boolean: ["true", "false"],
    bracket: ["{", "}", "(", ")"],
    keyword: ['code', 'let', "for", "function", "const",
      "if", "else", "break", "continue", "default", "switch", "case"],
    Identifier: /[\w]+/,
  });

  function stringToSig(str) {
    const clean = str.trim();

    if (clean.indexOf("event") === 0) {
      const inter = new utils.Interface([str]);
      return inter.events[Object.keys(inter.events)[0]].topic;
    } else {
      const inter = new utils.Interface([str,]);
      return inter.functions[Object.keys(inter.functions)[0]].sighash;
    }
  }

  function flatDeep(arr, d = 1) {
     return d > 0 ? arr.reduce((acc, val) => acc.concat(Array.isArray(val) ? flatDeep(val, d - 1) : val), [])
                  : arr.slice();
  };

  function mapDeep(arr, f) {
    return Array.isArray(arr) ? arr.map(v => mapDeep(v, f)) : f(arr);
  }

  function _filter(arr, kind, stopKind = null) {
    var isStopKind = false;

    return flatDeep(arr, 10000000)
      .filter(v => {
        if (v.type === stopKind) {
          isStopKind = true;
        }

        if (isStopKind === true) {
          return false;
        }

        return v.type === kind;
      });
  }

  function _filterKind(arr, kind, stopKind = null) {
    var isStopKind = false;

    return flatDeep(arr, 10000000)
      .filter(v => {
        if (v.kind === stopKind) {
          isStopKind = true;
        }

        if (isStopKind === true) {
          return false;
        }

        return v.kind === kind;
      });
  }

  const stateKind = kind => d => {
    d[0].kind = kind;
    return d;
  }

  function functionCall(d) {
    d[0].type = 'FunctionCallIdentifier';
    return d;
  }

  function extractArray(d) {
    return d;
  }

  const sliceMethod = `function mslice(position, length) -> result {
      if gt(length, 32) { revert(0, 0) } // protect against overflow

      result := div(mload(position), exp(2, safeSub(256, safeMul(length, 8))))
  }`;
  const sliceObject = {
    value: sliceMethod,
    type: 'MethodInjection',
    text: sliceMethod,
    toString: () => sliceMethod,
  };
%}

@lexer lexer

Yul -> (_ Chunk):* _ {% function(d) { return d; } %}
Chunk -> ObjectDefinition | CodeDefinition {% function(d) { return d; } %}
ObjectDefinition -> %objectKeyword _ %StringLiteral _ "{" ( _ objectStatement):* _ "}"
objectStatement -> CodeDefinition {% function(d) { return d[0]; } %}
  | DataDeclaration {% function(d) { return d[0]; } %}
  | ObjectDefinition {% function(d) { return d[0]; } %}
DataDeclaration -> %dataKeyword _ %StringLiteral _ (%StringLiteral | %HexLiteral)
CodeDefinition -> %codeKeyword _ Block {%
  function (d) {
    const usesSlice = _filter(d, 'FunctionCallIdentifier')
      .filter(v => v.value === 'mslice')
      .length > 0;
    d[2].splice(1, 0, sliceObject)

    return d;
  }
%}
Block -> "{" _ Statement (_ Statement):* _ "}" {% function(d) {
  return d;
} %}
  | "{" _ "}" {% extractArray %}
Switch -> "switch" _ Expression _ SwitchDefinitions
SwitchDefinitions -> SwitchDefinition (_ SwitchDefinition):* {%
  function(d) {
    const clean = d.filter(v => v);
    return d;
  }
%}
SigLiteral -> %SigLiteral {%
  function(d) {
    const sig = stringToSig(d[0].value.trim().slice(4).slice(0, -1));
    return { type: 'HexNumber', value: sig, text: sig };
  }
%}
TopicLiteral -> %TopicLiteral {%
  function(d) {
    const sig = stringToSig(d[0].value.trim().slice(6, -1));
    return { type: 'HexNumber', value: sig, text: sig };
  }
%}
Boolean -> %boolean {% function(d) {
  if (d[0].value === "true") {
    return { type: 'HexNumber', value: '0x01', text: '0x01' };
  } else {
    return { type: 'HexNumber', value: '0x00', text: '0x00' };
  }
} %}
ForLoop -> "for" _ "{" (_ Statement):* _ "}" _ Expression _ "{" (_ Statement):* _ "}" _ Block
BreakContinue -> "break" | "continue"
SwitchDefinition -> Case | Default
Case -> "case" _ Literal _ Block
Default -> "default" _ Block
Statement -> FunctionDefinition
  | FunctionCall
  | ForLoop
  | VariableDeclaration
  | ConstantDeclaration
  | IfStatement
  | Assignment
  | Switch
  | BreakContinue
IfStatement -> "if" _ Expression _ Block
Literal -> %StringLiteral
  | %NumberLiteral
  | %HexNumber
  | SigLiteral
  | TopicLiteral
Expression -> Literal
  | %Identifier
  | FunctionCall
  | Boolean
FunctionCall -> %Identifier _ "(" _ Expression ( _ "," _ Expression):* _ ")" {% functionCall %}
  | %Identifier _ "(" _ ")" {% functionCall %}
IdentifierList -> %Identifier (_ "," _ %Identifier):* {% extractArray %}
VariableDeclaration -> "let" _ IdentifierList _ ":=" _ Expression
ConstantDeclaration -> "const" _ IdentifierList _ ":=" _ Expression {%
  function (d) {
    // Change const to let
    d[0].value = 'let';
    d[0].text = 'let';
    d[0].type = '__constant';
    d[0].__itendifiers = _filter(d, 'Identifier', 'equate')
      .map(v => v.value);
    d[0].__value = _filterKind(d, 'ExpressionValue');
    d[0].__map = d[0].__itendifiers.reduce((acc, v) => Object.assign(acc, {
      [v]: d[0].__value,
    }), {});
    d.__constant = true;

    return d;
  }
%}
Assignment -> IdentifierList _ ":=" _ Expression
FunctionDefinition -> "function" _ %Identifier _ "(" _ IdentifierList _ ")" _ "->" _ IdentifierList _ Block
  | "function" _ %Identifier _ "(" _ ")" _ "->" _ IdentifierList _ Block
  | "function" _ %Identifier _ "(" _ ")" _ "->" _ "(" _ ")" _ Block
  | "function" _ %Identifier _ "(" _ IdentifierList _ ")" _ Block
  | "function" _ %Identifier _ "(" _ ")" _ Block
Empty -> %space
  | %multiComment
  | %singleLineComment
_ -> (Empty):*