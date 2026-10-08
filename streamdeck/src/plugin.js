import streamDeck from '@elgato/streamdeck';
import { StatusAction } from './status-action.js';

streamDeck.actions.registerAction(new StatusAction());
streamDeck.connect();
