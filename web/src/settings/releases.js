// The Releases page of Settings (settings/Releases.svelte): the rows of `hs sys release show` as one model, and the words for it. Pure, so a test runs it in plain node.
// Rows are [key, ...fields]: channel, installed, offer (channel, ref, state) for each channel, ref, state, signed.

export const CHANNELS = ['stable', 'beta', 'edge'];

// Who each channel is for (one line each; beta and edge are never applied unattended)
export const WHO = {
  stable: 'The newest signed release. The right one for every server that holds data.',
  beta: 'The newest signed beta or release, for a second server or a test machine. It is not applied by itself: a person starts the update.',
  edge: 'The head of the development branch, only for a server whose data may be lost. It is not applied by itself: a person starts the update.',
};

export function releaseModel(rows) {
  if (!Array.isArray(rows) || !rows.length) return null;
  const m = { channel: 'stable', installed: '-', ref: '-', state: 'none', signed: '-', offers: {} };
  for (const r of rows) {
    if (r[0] === 'channel') m.channel = r[1];
    else if (r[0] === 'installed') m.installed = r[1];
    else if (r[0] === 'ref') m.ref = r[1];
    else if (r[0] === 'state') m.state = r[1];
    else if (r[0] === 'signed') m.signed = r[1];
    else if (r[0] === 'offer') m.offers[r[1]] = { ref: r[2], state: r[3] };
  }
  return m;
}

// What the next update does on the current channel: a sentence for the page and a dot state
export function nextUpdate(m) {
  if (!m) return null;
  switch (m.state) {
    case 'current': return { state: 'ok', text: 'No update is waiting: this server runs {ref} already.' };
    case 'kept': return { state: 'info', text: 'The installed version stays: {ref} is older, so there is no downgrade. Updates continue when the channel catches up.' };
    case 'update': return { state: 'warn', text: 'The next update installs {ref}.' };
    case 'unknown': return { state: 'info', text: '{ref} is not fetched yet: the next update looks for it.' };
    default: return { state: 'off', text: 'There is no release tag for this channel yet: the next update follows the current branch.' };
  }
}

// The plan arguments for choosing a channel (the web asks `hs sys release plan channel <name>`)
export const planArgs = (channel) => ['channel', channel];
