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
  'Sort by': 'Sortieren nach', 'Update all': 'Alle aktualisieren',
};

export const tr = (s) => (lang.code === 'de' && typeof s === 'string' ? (de[s] ?? s) : s);
