import { mount } from 'svelte';
import '@phosphor-icons/web/regular';
import './tokens.css';
import './base.css';
import { initTheme } from './theme.svelte.js';
import App from './App.svelte';

initTheme();
mount(App, { target: document.getElementById('app') });
