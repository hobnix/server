<script>
  // The account step: who is signed in, the server name (read only) and the language of this interface. The page's Next calls save().
  import Kv from '../ui/Kv.svelte';
  import ChoiceList from '../ui/ChoiceList.svelte';
  import { ui, openPlan } from '../ui.svelte.js';
  let { user = '', save = $bindable(null) } = $props();
  const LANGS = [{ id: 'en', label: 'English', text: '' }, { id: 'de', label: 'Deutsch', text: '' }];
  let lang = $state(ui.features.language || 'en');
  // true: nothing to change, advance; false: a plan was opened
  save = () => {
    if (lang === (ui.features.language || 'en')) return true;
    openPlan('config', ['set', 'language', lang], 'Interface language');
    return false;
  };
</script>

<Kv cols={2} items={[{ k: 'Administrator', v: user }, { k: 'Server name', v: ui.host }]} />
<p class="muted">A rename needs a rebuild: <code>hs config set hostName</code>.</p>
<ChoiceList options={LANGS} value={lang} onpick={(id) => (lang = id)} label="Language" />
