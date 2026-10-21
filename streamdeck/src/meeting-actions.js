/*
 * The Mute and Leave keys, for the Teams or Zoom meeting you're in. The app
 * does the pressing (Sources/Meeting/MeetingKeys.swift): the meeting's own
 * button through Accessibility, or failing that its keyboard shortcut sent
 * to the meeting window. These keys only ask, and show what it says:
 *
 *   Mute   green LIVE, red MUTED, MIC ? when the meeting's mute can't be
 *          read, dark outside a meeting
 *   Leave  red LEAVE in a meeting. A press leaves (on release); held a
 *          second, it ends a Zoom meeting you host for everyone (anything
 *          else, it leaves). Set to "hold" in its settings, it leaves only
 *          when held half a second — a tap says HOLD — and ends at 1.6
 *          seconds. Outside a meeting, red END while the sign shows a
 *          calendar event that can be ended early (a call taken on your
 *          phone, a meeting that finished early): a press — or a hold, set
 *          to "hold" — says it's over, and the sign moves on. Dark otherwise
 *
 * A press while the last one is still going is ignored, so mute can't
 * toggle twice. One the app couldn't do shows the warning triangle.
 */
import streamDeck, { SingletonAction } from '@elgato/streamdeck';
import { pressEnd, pressEndEvent, pressLeave, pressMute } from './app.js';
import { leaveFace, meetingKeyImage, muteFace } from './key.js';
import { latest, lost, ready, share, watch } from './live.js';

const LEAVE_HOLD_MS = 600;                       // set to "hold": leaves once held this long
const END_MS = { press: 1000, hold: 1600 };      // held this long: ends a Zoom meeting you host for everyone
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
  downs = new Map();        // key id -> { at, hold, timer } while the key is down
  holdShown = new Map();    // key id -> until when HOLD shows

  image(view, id) {
    return meetingKeyImage('leave', leaveFace(view), (this.holdShown.get(id) || 0) > Date.now());
  }

  onKeyDown(ev) {
    // no Teams or Zoom meeting, but an event on the sign: END says it's over
    const view = latest();
    const ending = !!(view && !view.meeting && view.canEnd);
    // a multi-action has no key-up: just leave (or end)
    if (ev.payload.isInMultiAction) return this.press(ev.action, ending ? pressEndEvent : pressLeave);
    const hold = !!(ev.payload.settings && ev.payload.settings.confirm === 'hold');
    this.clear(ev.action.id);
    // held long enough in a meeting: end it for everyone, there and then
    const timer = ending ? null : setTimeout(() => {
      this.downs.delete(ev.action.id);
      this.press(ev.action, pressEnd);
    }, hold ? END_MS.hold : END_MS.press);
    this.downs.set(ev.action.id, { at: Date.now(), hold, timer, ending });
  }

  onKeyUp(ev) {
    const down = this.downs.get(ev.action.id);
    if (!down) return;                            // ended already
    this.clear(ev.action.id);
    if (down.hold && Date.now() - down.at < LEAVE_HOLD_MS) return this.sayHold(ev.action.id);
    return this.press(ev.action, down.ending ? pressEndEvent : pressLeave);
  }

  /* Let go too soon on a held key: say to hold it. */
  async sayHold(id) {
    this.holdShown.set(id, Date.now() + HOLD_SHOWN_MS);
    await this.draw(latest());
    setTimeout(() => {
      this.holdShown.delete(id);
      this.draw(latest());
    }, HOLD_SHOWN_MS + 50);
  }

  onWillDisappear(ev) {
    this.clear(ev.action.id);
    this.holdShown.delete(ev.action.id);
    super.onWillDisappear(ev);
  }

  clear(id) {
    const down = this.downs.get(id);
    if (!down) return false;
    clearTimeout(down.timer);
    this.downs.delete(id);
    return true;
  }
}
