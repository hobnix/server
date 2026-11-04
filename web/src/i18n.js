// German for the words of the shell: the resource tree, page headers, tab rows and table headers. The English text is the key (as in scripts/lib/i18n.sh);
// a text that is not here stays English. The page bodies are still English only; the guides have their own language switch.
// tr('Snapshots') -> 'Wiederherstellungspunkte' while the language is German. Reactive: it reads lang.code.
import { lang } from './lang.svelte.js';

const de = {
  Storage: 'Speicher', Pools: 'Pools', Disks: 'Festplatten', Shares: 'Freigaben', Encryption: 'Verschlüsselung', Vault: 'Tresor',
  Instances: 'Instanzen', Apps: 'Apps', Services: 'Dienste', Network: 'Netzwerk', Identity: 'Identität', Groups: 'Gruppen', Users: 'Benutzer',
  Certificates: 'Zertifikate', Monitoring: 'Überwachung', Hardware: 'Hardware', Diagnostics: 'Diagnose', Protection: 'Schutz', Backup: 'Datensicherung',
  'Expiry dates': 'Ablaufdaten', Operations: 'Betrieb', Health: 'Zustand', Notifications: 'Benachrichtigungen', Docs: 'Anleitungen', Settings: 'Einstellungen',
  Setup: 'Einrichtung', Summary: 'Übersicht', Servers: 'Server', Data: 'Daten', Snapshots: 'Wiederherstellungspunkte', Logs: 'Protokolle', Route: 'Route',
  Overview: 'Überblick', Info: 'Info', Members: 'Mitglieder', Router: 'Router', 'Remote shares': 'Freigaben anderer Server', Permissions: 'Berechtigungen',
  Name: 'Name', Type: 'Typ', State: 'Status', Address: 'Adresse', Kind: 'Art', Size: 'Größe', Usage: 'Belegung', Layout: 'Aufbau', Level: 'Stufe', Share: 'Freigabe',
  Through: 'Über', Volume: 'Volumen', Item: 'Eintrag', 'Used by': 'Verwendet von', Server: 'Server', Host: 'Rechner', Problems: 'Probleme', Parts: 'Teile',
  'Last snapshot': 'Letzter Wiederherstellungspunkt', 'Last sync': 'Letzte Synchronisierung', 'Last answer': 'Letzte Antwort', Read: 'Abfrage', Every: 'Alle', Kept: 'Gehalten', Takes: 'Dauer',
  Create: 'Erstellen', Delete: 'Löschen', Restart: 'Neu starten', Start: 'Starten', Stop: 'Stoppen', Close: 'Schließen', Password: 'Passwort',
  "What's new": 'Neuigkeiten',
  General: 'Allgemein', 'Network and DNS': 'Netzwerk und DNS', 'Users and access': 'Benutzer und Zugang', Updates: 'Aktualisierungen',
  Capabilities: 'Funktionen', Advanced: 'Erweitert', Backups: 'Datensicherungen',
  Next: 'Weiter', Back: 'Zurück', Review: 'Überprüfen', 'Back to the questions': 'Zurück zu den Fragen', Change: 'Ändern', 'Apply…': 'Anwenden…', recommended: 'empfohlen',   // the wizard's buttons
  'Sort by': 'Sortieren nach', 'Update all': 'Alle aktualisieren',
  // Settings, Releases (settings/Releases.svelte, settings/releases.js)
  Releases: 'Versionen', 'Which version this server follows when it updates.': 'Welcher Version dieser Server beim Aktualisieren folgt.',
  'This server': 'Dieser Server', 'Installed version': 'Installierte Version', 'Next update': 'Nächstes Update', Signature: 'Signatur', valid: 'gültig', 'not valid': 'ungültig',
  Stable: 'Stabil', Beta: 'Beta', Edge: 'Edge', current: 'aktuell', 'Would install': 'Würde installieren', 'Switch to': 'Wechseln zu', 'Loading…': 'Lädt…',
  'Shows the plan first; nothing is installed': 'Zeigt zuerst den Plan; es wird nichts installiert', 'The release channel could not be read.': 'Der Versionskanal konnte nicht gelesen werden.',
  'The newest signed release. The right one for every server that holds data.': 'Die neueste signierte Version. Die richtige für jeden Server mit Daten.',
  'The newest signed beta or release, for a second server or a test machine. It is not applied by itself: a person starts the update.': 'Die neueste signierte Beta oder Version, für einen zweiten Server oder eine Testmaschine. Sie wird nicht von selbst eingespielt: eine Person startet das Update.',
  'The head of the development branch, only for a server whose data may be lost. It is not applied by itself: a person starts the update.': 'Der Stand des Entwicklungszweigs, nur für einen Server, dessen Daten verloren gehen dürfen. Er wird nicht von selbst eingespielt: eine Person startet das Update.',
  'No update is waiting: this server runs {ref} already.': 'Kein Update wartet: dieser Server läuft schon mit {ref}.',
  'The installed version stays: {ref} is older, so there is no downgrade. Updates continue when the channel catches up.': 'Die installierte Version bleibt: {ref} ist älter, es gibt kein Zurück. Updates gehen weiter, wenn der Kanal aufgeholt hat.',
  'The next update installs {ref}.': 'Das nächste Update installiert {ref}.', '{ref} is not fetched yet: the next update looks for it.': '{ref} ist noch nicht geholt: das nächste Update sucht danach.',
  'There is no release tag for this channel yet: the next update follows the current branch.': 'Für diesen Kanal gibt es noch kein Release-Tag: das nächste Update folgt dem aktuellen Zweig.',
  'Moving to an older channel keeps the installed version: the server does not go back, it waits until the channel catches up.': 'Der Wechsel zu einem älteren Kanal behält die installierte Version: der Server geht nicht zurück, er wartet, bis der Kanal aufgeholt hat.',
};

export const tr = (s) => (lang.code === 'de' && typeof s === 'string' ? (de[s] ?? s) : s);
