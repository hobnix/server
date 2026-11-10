// German texts of the questions a recipe asks while it runs, by question key (ADR 0018 rule 16): `<recipe>.<KEY>` first, then `<KEY>`, then the English
// label of the job record. The refusal texts the shared helpers (scripts/recipes/_lib.sh) send are keyed by their English sentence. Plain text only;
// append-only like i18n.js. A package may bring its own `label.de` later; this table is for the shared questions.
export const questionTexts = {
  de: {
    FIXED_IP: 'Feste Adresse für diesen Container (der Router reserviert sie)',
    PORT: 'Port der Weboberfläche',
    'That value does not fit here.': 'Dieser Wert passt hier nicht.',
    'That is not an address like 10.10.95.25.': 'Das ist keine Adresse wie 10.10.95.25.',
    'UniFi does not accept that address (taken, or inside the range the router hands out).': 'UniFi nimmt diese Adresse nicht an (schon vergeben oder im Bereich, den der Router verteilt).',
  },
};
