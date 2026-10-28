// Tooltip placement (web/src/ui/tooltip-place.js): preferred side, flipped when there is no room, clamped into the viewport.
import assert from 'node:assert/strict';
import { placeTip } from '../web/src/ui/tooltip-place.js';

const rect = (left, top, w = 30, h = 30) => ({ left, top, right: left + w, bottom: top + h, width: w, height: h });
const size = { w: 120, h: 28 };
const VW = 1000, VH = 700;

// above the trigger, centred
let p = placeTip(rect(400, 300), size, VW, VH, 'top');
assert.equal(p.side, 'top');
assert.equal(p.left, 400 + 15 - 60);
assert.equal(p.top, 300 - 8 - 28);

// below the trigger
p = placeTip(rect(400, 300), size, VW, VH, 'bottom');
assert.equal(p.side, 'bottom');
assert.equal(p.top, 330 + 8);

// no room above (trigger at the top edge): flips to the bottom
p = placeTip(rect(400, 10), size, VW, VH, 'top');
assert.equal(p.side, 'bottom');

// no room below: flips to the top
p = placeTip(rect(400, 660), size, VW, VH, 'bottom');
assert.equal(p.side, 'top');

// no room on either side: stays on the side with more room, and is clamped into the viewport
p = placeTip(rect(400, 340, 30, 30), { w: 120, h: 340 }, VW, VH, 'top');
assert.ok(p.top >= 8 && p.top + 340 <= VH - 8, 'clamped vertically');

// left and right
p = placeTip(rect(500, 300), size, VW, VH, 'right');
assert.equal(p.side, 'right');
assert.equal(p.left, 530 + 8);
p = placeTip(rect(900, 300), size, VW, VH, 'right');
assert.equal(p.side, 'left', 'no room on the right: flipped');

// clamped horizontally at both edges
p = placeTip(rect(0, 300), size, VW, VH, 'top');
assert.equal(p.left, 8);
p = placeTip(rect(980, 300, 20, 30), size, VW, VH, 'top');
assert.equal(p.left, VW - 8 - 120);

// an unknown side is the default (top)
assert.equal(placeTip(rect(400, 300), size, VW, VH, 'diagonal').side, 'top');

console.log('tooltip ok');
