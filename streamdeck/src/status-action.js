/*
 * The Status key. Shows what the sign says, asking the app once a second
 * on the second, so its countdown turns with the bar's. A press starts or
 * ends Do Not Disturb, as a double-click on the bar does; on a call, where
 * the sign stays ON A CALL, a tick shows the press counted.
 */
import streamDeck, { SingletonAction } from '@elgato/streamdeck';
import { getStatus, toggleDND } from './app.js';
import { keyImage } from './key.js';

export class StatusAction extends SingletonAction {
  manifestId = 'com.woodall.busybarsign.status';

  view = null;              // the app's last answer; null while it isn't answering
  shown = new Map();        // key id -> the picture on it, so an unchanged one isn't resent
  polling = false;
  answering = null;         // so the log only notes a change

  onWillAppear(ev) {
    this.shown.delete(ev.action.id);
    if (this.polling) return this.draw();
    this.polling = true;
    return this.tick();
  }

  onWillDisappear(ev) {
    this.shown.delete(ev.action.id);
  }

  async onKeyDown(ev) {
    const before = this.view && this.view.state;
    try {
      this.view = await toggleDND();
      this.heard(null);
    } catch (e) {
      this.heard(e);
      await ev.action.showAlert();
      return;
    }
    await this.draw();
    if (this.view.state === before) await ev.action.showOk();
  }

  async tick() {
    if (this.actions.length === 0) {               // no Status key showing: stop asking
      this.polling = false;
      return;
    }
    try {
      this.view = await getStatus();
      this.heard(null);
    } catch (e) {
      this.view = null;
      this.heard(e);
    }
    await this.draw();
    // just after the next second turns over, as the bar's clock does
    setTimeout(() => this.tick(), 1030 - (Date.now() % 1000));
  }

  async draw() {
    try {
      const image = keyImage(this.view, new Date());
      await Promise.all(this.actions.toArray().map(async (action) => {
        if (!action.isKey() || this.shown.get(action.id) === image) return;
        this.shown.set(action.id, image);
        await action.setImage(image);
      }));
    } catch (e) {
      streamDeck.logger.error(`Couldn't draw the key: ${e.stack || e}`);
    }
  }

  heard(error) {
    const answering = error === null;
    if (answering === this.answering) return;
    this.answering = answering;
    if (answering) streamDeck.logger.info('Busy Bar Sign is answering');
    else streamDeck.logger.warn(`Busy Bar Sign isn't answering: ${error.message}`);
  }
}
