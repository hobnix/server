// Highlighting of an .env text as a CodeMirror StreamLanguage tokenizer (cm.js wraps it). Pure: the stream is only used through
// sol, peek, match, eat and skipToEnd.
export const envTokenizer = {
  name: 'env',
  startState: () => ({ value: false }),
  token(stream, state) {
    if (stream.sol()) {
      state.value = false;
      if (stream.peek() === '#') { stream.skipToEnd(); return 'comment'; }
    }
    if (state.value) { stream.skipToEnd(); return 'string'; }
    if (stream.match(/^[A-Za-z_][A-Za-z0-9_]*/)) return 'variableName';
    if (!stream.sol() && stream.eat('=')) { state.value = true; return 'operator'; }
    stream.skipToEnd();
    return 'invalid';
  },
};
