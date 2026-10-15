import streamDeck from '@elgato/streamdeck';
import { LeaveAction, MuteAction } from './meeting-actions.js';
import { StatusAction } from './status-action.js';

streamDeck.actions.registerAction(new StatusAction());
streamDeck.actions.registerAction(new MuteAction());
streamDeck.actions.registerAction(new LeaveAction());
streamDeck.connect();
