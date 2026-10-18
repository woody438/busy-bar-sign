/*
 * The Status key. Shows what the sign says, from the app's answer once a
 * second on the second (live.js), so its countdown turns with the bar's. A
 * press does what a double-click on the bar does: starts or ends Do Not
 * Disturb or, during LATE FOR CALL or MTG, says you're there in person, so
 * the sign shows MEETING (the app decides which). On a call, where the sign
 * stays ON A CALL, a tick shows the press counted.
 */
import streamDeck, { SingletonAction } from '@elgato/streamdeck';
import { toggleDND } from './app.js';
import { keyImage } from './key.js';
import { latest, lost, ready, share, watch } from './live.js';

export class StatusAction extends SingletonAction {
  manifestId = 'com.woodall.busybarsign.status';

  shown = new Map();        // key id -> the picture on it, so an unchanged one isn't resent

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

  async onKeyDown(ev) {
    const before = latest() && latest().state;
    let view;
    try {
      view = await toggleDND();
    } catch (e) {
      lost(e);
      await ev.action.showAlert();
      return;
    }
    await share(view);
    if (view.state === before) await ev.action.showOk();
  }

  async draw(view) {
    try {
      const image = keyImage(view, new Date());
      await Promise.all(this.actions.toArray().map(async (action) => {
        if (!action.isKey() || this.shown.get(action.id) === image) return;
        this.shown.set(action.id, image);
        await action.setImage(image);
      }));
    } catch (e) {
      streamDeck.logger.error(`Couldn't draw the key: ${e.stack || e}`);
    }
  }
}
