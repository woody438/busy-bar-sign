/*
 * One look at the app a second for every key showing, whatever the action:
 * the Status, Mute and Leave keys all draw from the same answer. Asks just
 * after each second turns over, as the bar's clock does, and stops once no
 * key of ours is on any Stream Deck.
 */
import streamDeck from '@elgato/streamdeck';
import { getStatus } from './app.js';

const actions = new Set();      // each with showing() and draw(view)
let view = null;                // the app's last answer; null while it isn't answering
let asked = false;              // whether the app's been asked yet
let polling = false;
let answering = null;           // so the log only notes a change

/* The app's last answer. */
export const latest = () => view;

/* Whether there's an answer (or a silence) to draw yet: a key that appears
   first waits for it, rather than saying APP OFF for a moment. */
export const ready = () => asked;

/* Starts asking, if nothing is yet, for an action whose key has appeared. */
export function watch(action) {
  actions.add(action);
  if (polling) return;
  polling = true;
  tick();
}

/* An answer from a press: every key shows it straight away. */
export async function share(next) {
  view = next;
  asked = true;
  heard(null);
  await drawAll();
}

/* A press the app didn't answer. */
export function lost(error) {
  heard(error);
}

async function drawAll() {
  await Promise.all([...actions].filter((a) => a.showing()).map((a) => a.draw(view)));
}

async function tick() {
  if (![...actions].some((a) => a.showing())) {     // no key of ours showing: stop asking
    polling = false;
    asked = false;                                  // and a key that comes back waits for a fresh answer
    return;
  }
  try {
    view = await getStatus();
    heard(null);
  } catch (e) {
    view = null;
    heard(e);
  }
  asked = true;
  await drawAll();
  setTimeout(tick, 1030 - (Date.now() % 1000));
}

function heard(error) {
  const now = error === null;
  if (now === answering) return;
  answering = now;
  if (now) streamDeck.logger.info('Busy Bar Sign is answering');
  else streamDeck.logger.warn(`Busy Bar Sign isn't answering: ${error.message}`);
}
