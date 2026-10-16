/*
 * The away keys: say where you are when you leave your desk. The app keeps
 * it (Sources/Away.swift) and shows it on the sign, and a few seconds after
 * the last press starts the screen saver, which locks the Mac with the sign
 * on every screen. Unlocking clears it.
 *
 *   Nearby  NEARBY: in the building, not at your desk. Press again: off
 *   Lunch      LUNCH. Press again: off
 *   Back In    BACK IN with a countdown: ten minutes a press, so three
 *              presses for half an hour. Hold it a second: back at your desk
 *
 * Each key is lit while it's the one on, dimmed while it isn't.
 */
import streamDeck, { SingletonAction } from '@elgato/streamdeck';
import { endAway, pressAway } from './app.js';
import { awayKeyImage } from './key.js';
import { latest, lost, ready, share, watch } from './live.js';

const END_MS = 1000;            // Back In held this long: back at your desk

class AwayAction extends SingletonAction {
  shown = new Map();        // key id -> the picture on it

  onWillAppear(ev) {
    this.shown.delete(ev.action.id);
    watch(this);
    if (ready()) return this.draw(latest());
  }

  onWillDisappear(ev) {
    this.shown.delete(ev.action.id);
  }

  showing() {
    return this.actions.length > 0;
  }

  /* Asks the app, and every key shows its answer; false if it didn't answer. */
  async press(action, ask) {
    try {
      await share(await ask());
      return true;
    } catch (e) {
      lost(e);
      await action.showAlert();
      return false;
    }
  }

  async draw(view) {
    try {
      const image = awayKeyImage(this.kind, view, new Date());
      await Promise.all(this.actions.toArray().map(async (action) => {
        if (!action.isKey() || this.shown.get(action.id) === image) return;
        this.shown.set(action.id, image);
        await action.setImage(image);
      }));
    } catch (e) {
      streamDeck.logger.error(`Couldn't draw the ${this.kind} key: ${e.stack || e}`);
    }
  }
}

export class NearbyAction extends AwayAction {
  manifestId = 'com.woodall.busybarsign.wandering';     // its first name, kept so keys already placed carry on
  kind = 'nearby';

  onKeyDown(ev) {
    return this.press(ev.action, () => pressAway('nearby'));
  }
}

export class LunchAction extends AwayAction {
  manifestId = 'com.woodall.busybarsign.lunch';
  kind = 'lunch';

  onKeyDown(ev) {
    return this.press(ev.action, () => pressAway('lunch'));
  }
}

export class BackInAction extends AwayAction {
  manifestId = 'com.woodall.busybarsign.backin';
  kind = 'backIn';
  downs = new Map();        // key id -> the hold timer, while the key is down

  onKeyDown(ev) {
    // a multi-action has no key-up: just ten minutes more
    if (ev.payload.isInMultiAction) return this.press(ev.action, () => pressAway('backIn'));
    this.clear(ev.action.id);
    this.downs.set(ev.action.id, setTimeout(async () => {
      this.downs.delete(ev.action.id);
      if (await this.press(ev.action, endAway)) await ev.action.showOk();
    }, END_MS));
  }

  onKeyUp(ev) {
    if (!this.clear(ev.action.id)) return;        // held: ended already
    return this.press(ev.action, () => pressAway('backIn'));
  }

  onWillDisappear(ev) {
    this.clear(ev.action.id);
    super.onWillDisappear(ev);
  }

  clear(id) {
    if (!this.downs.has(id)) return false;
    clearTimeout(this.downs.get(id));
    this.downs.delete(id);
    return true;
  }
}
