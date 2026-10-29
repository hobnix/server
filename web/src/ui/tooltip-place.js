// Where a tooltip goes (pure, so node can test it): on the preferred side of the trigger, flipped to the other side when there is no room,
// clamped into the viewport. `r` is the trigger's rect, `size` the tooltip's { w, h }. Returns { left, top, side } in viewport pixels.
export function placeTip(r, size, vw, vh, side = 'top', gap = 8, margin = 8) {
  const room = { top: r.top - margin, bottom: vh - r.bottom - margin, left: r.left - margin, right: vw - r.right - margin };
  const need = { top: size.h + gap, bottom: size.h + gap, left: size.w + gap, right: size.w + gap };
  const opposite = { top: 'bottom', bottom: 'top', left: 'right', right: 'left' };
  let s = side in opposite ? side : 'top';
  if (room[s] < need[s] && room[opposite[s]] > room[s]) s = opposite[s];
  let left, top;
  if (s === 'top' || s === 'bottom') {
    left = r.left + r.width / 2 - size.w / 2;
    top = s === 'top' ? r.top - gap - size.h : r.bottom + gap;
  } else {
    top = r.top + r.height / 2 - size.h / 2;
    left = s === 'left' ? r.left - gap - size.w : r.right + gap;
  }
  left = Math.max(margin, Math.min(left, vw - margin - size.w));
  top = Math.max(margin, Math.min(top, vh - margin - size.h));
  return { left, top, side: s };
}
