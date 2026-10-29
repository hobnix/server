// Hardware passthrough shapes and reason texts (web/src/pages/instances/devices.js).
import { hwOf, devOf, canPass, reasonText, usbOptions, usbIdOk } from '../web/src/pages/instances/devices.js';
import { readFileSync } from 'node:fs';

let ok = 0, bad = 0;
const check = (name, cond, extra = '') => { if (cond) { ok++; console.log(`  ok    ${name}`); } else { bad++; console.log(`  FAIL  ${name} ${extra}`); } };

const h = hwOf(['gpu', '0000:01:00.0', '10de:1c82', '-', 'GP107', 'nvidia', '12', 'nvidia-host', 'nvidia-recipe', '-', '1']);
check('hwOf maps - to the empty string', h.vendor === '' && h.usedBy === '' && h.kind === 'gpu' && h.iommu === '12' && h.vidpid === '10de:1c82');
const d = devOf(['usb-04f9-0042', 'usb', '04f9:0042', 'no', '-', 'instance', '-']);
check('devOf maps - to the empty string and yes/no to a boolean', d.with === '' && d.product === '' && d.present === false && d.from === 'instance');
check('devOf present yes', devOf(['a', 'pci', 'x', 'yes', 'p', 'profile', 'b']).present === true);

check('canPass picks the vm field for a VM', canPass(h, true).ok === false && canPass(h, true).why === reasonText['nvidia-host']);
check('canPass picks the ct field for a container', canPass(h, false).why === reasonText['nvidia-recipe']);
check('canPass ok', canPass({ ...h, vm: 'ok' }, true).ok === true);
check('an unknown word is shown as it is', canPass({ ...h, ct: 'weird' }, false).why === 'weird');

const uo = usbOptions([['usb', '04f9:0042', '04f9:0042', 'Brother', 'HL-L2300', 'usblp', '-', 'ok', 'ok', 'cups', '1'], ['gpu', '0000:01:00.0', '10de:1c82', '-', 'GP107', 'nvidia', '12', 'x', 'x', '-', '1'], ['usb', '1d6b:0002', '1d6b:0002', '-', '-', '-', '-', 'ok', 'ok', '-', '1']]);
check('usbOptions keeps usb rows only', uo.length === 2 && uo[0].value === '04f9:0042' && uo[1].value === '1d6b:0002');
check('usbOptions labels with the product and the id', uo[0].label.startsWith('HL-L2300 (04f9:0042)') && uo[0].label.includes('cups') && uo[1].label === '1d6b:0002 (1d6b:0002)');
check('usbIdOk', usbIdOk('04f9:0042') && !usbIdOk('04F9:0042') && !usbIdOk('04f9:004') && !usbIdOk('../x'));

// every reason word of the closed set in the header of scripts/ct-device.sh has a text
const src = readFileSync(new URL('../scripts/ct-device.sh', import.meta.url), 'utf8');
const line = src.split('\n').find((l) => /^#\s+host-disk /.test(l)) || '';
const words = line.replace(/^#\s+/, '').trim().split(/\s+/);
check('the header lists the reason words', words.length >= 9, line);
for (const w of words) check(`reason word ${w} has a text`, typeof reasonText[w] === 'string' && reasonText[w].length > 0);
check('no text without a word', Object.keys(reasonText).every((k) => words.includes(k)));

console.log(`${ok} ok, ${bad} failed`);
process.exit(bad ? 1 : 0);
