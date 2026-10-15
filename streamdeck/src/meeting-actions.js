/*
 * The Mute and Leave keys, for the Teams or Zoom meeting you're in. The app
 * does the pressing (Sources/Meeting/MeetingKeys.swift): the meeting's own
 * button through Accessibility, or failing that its keyboard shortcut sent
 * to the meeting window. These keys only ask, and show what it says:
 *
 *   Mute   green LIVE, red MUTED, MIC ? when the meeting's mute can't be
 *          read, dark outside a meeting
 *   Leave  red LEAVE in a meeting, dark otherwise; set to "hold" in its
 *          settings, it leaves only when held half a second, and a tap
 *          says HOLD
 *
 * A press while the last one is still going is ignored, so mute can't
 * toggle twice. One the app couldn't do shows the warning triangle.
 */
import streamDeck, { SingletonAction } from '@elgato/streamdeck';
import { pressLeave, pressMute } from './app.js';
import { leaveFace, meetingKeyImage, muteFace } from './key.js';
import { latest, lost, ready, share, watch } from './live.js';

const HOLD_MS = 600;
const HOLD_SHOWN_MS = 1200;

class MeetingAction extends SingletonAction {
  shown = new Map();        // key id -> the picture on it
  busy = false;

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

  /* Asks the app to press, and shows how it went. */
  async press(action, ask) {
    if (this.busy) {
      streamDeck.logger.info(`${this.kind}: ignored, the last press is still going`);
      return;
    }
    this.busy = true;
    const before = latest();
    try {
      const answer = await ask();
      await share(answer.view);
      const ok = !!(answer.pressed && answer.pressed.ok);
      if (answer.pressed) streamDeck.logger.info(`${this.kind}: ${answer.pressed.message}`);
      if (!ok) await action.showAlert();
      else if (!(before && before.meeting)) await action.showOk();   // no meeting showed: say it went
    } catch (e) {
      lost(e);
      await action.showAlert();
    } finally {
      this.busy = false;
    }
  }

  /* This key's picture now. */
  image(view) {
    throw new Error('not implemented');
  }

  async draw(view) {
    try {
      await Promise.all(this.actions.toArray().map(async (action) => {
        if (!action.isKey()) return;
        const image = this.image(view, action.id);
        if (this.shown.get(action.id) === image) return;
        this.shown.set(action.id, image);
        await action.setImage(image);
      }));
    } catch (e) {
      streamDeck.logger.error(`Couldn't draw the ${this.kind} key: ${e.stack || e}`);
    }
  }
}

export class MuteAction extends MeetingAction {
  manifestId = 'com.woodall.busybarsign.mute';
  kind = 'mute';

  image(view) {
    return meetingKeyImage('mute', muteFace(view));
  }

  onKeyDown(ev) {
    return this.press(ev.action, pressMute);
  }
}

export class LeaveAction extends MeetingAction {
  manifestId = 'com.woodall.busybarsign.leave';
  kind = 'leave';
  timers = new Map();       // key id -> a hold under way
  holdShown = new Map();    // key id -> until when HOLD shows

  image(view, id) {
    return meetingKeyImage('leave', leaveFace(view), (this.holdShown.get(id) || 0) > Date.now());
  }

  onKeyDown(ev) {
    const hold = ev.payload.settings && ev.payload.settings.confirm === 'hold';
    if (!hold || ev.payload.isInMultiAction) return this.press(ev.action, pressLeave);
    this.clear(ev.action.id);
    this.timers.set(ev.action.id, setTimeout(() => {
      this.timers.delete(ev.action.id);
      this.press(ev.action, pressLeave);
    }, HOLD_MS));
  }

  async onKeyUp(ev) {
    if (!this.clear(ev.action.id)) return;
    // let go too soon: say to hold it
    this.holdShown.set(ev.action.id, Date.now() + HOLD_SHOWN_MS);
    await this.draw(latest());
    setTimeout(() => {
      this.holdShown.delete(ev.action.id);
      this.draw(latest());
    }, HOLD_SHOWN_MS + 50);
  }

  onWillDisappear(ev) {
    this.clear(ev.action.id);
    this.holdShown.delete(ev.action.id);
    super.onWillDisappear(ev);
  }

  clear(id) {
    const t = this.timers.get(id);
    if (!t) return false;
    clearTimeout(t);
    this.timers.delete(id);
    return true;
  }
}
