// Click on the dark area behind a read-only dialog closes it, but only when the press and the release both land on the backdrop:
// <div class="dialog-backdrop" use:backdropClose={onclose}>. A text selection dragged out of the dialog does not close it.
// Dialogs with input, a plan to confirm or a result to copy from do not use this: only Esc and their own buttons close them.
export function backdropClose(node, onclose) {
  let down = false;
  const press = (e) => { down = e.target === node; };
  const click = (e) => { if (down && e.target === node) onclose(); down = false; };
  node.addEventListener('mousedown', press);
  node.addEventListener('click', click);
  return {
    update(fn) { onclose = fn; },
    destroy() { node.removeEventListener('mousedown', press); node.removeEventListener('click', click); },
  };
}
