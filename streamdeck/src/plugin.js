import streamDeck from '@elgato/streamdeck';
import { BackInAction, LunchAction, WanderingAction } from './away-actions.js';
import { LeaveAction, MuteAction } from './meeting-actions.js';
import { StatusAction } from './status-action.js';

streamDeck.actions.registerAction(new StatusAction());
streamDeck.actions.registerAction(new MuteAction());
streamDeck.actions.registerAction(new LeaveAction());
streamDeck.actions.registerAction(new WanderingAction());
streamDeck.actions.registerAction(new LunchAction());
streamDeck.actions.registerAction(new BackInAction());
streamDeck.connect();
