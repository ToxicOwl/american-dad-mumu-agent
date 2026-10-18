# American Dad Arena Control

Deschide `AmericanDadArena.exe` din folderul `D:\Games\AmericanBot`.

## Butoane

- **Safe test (no taps)** — verifică poziția curentă din joc fără clickuri, Food, Ticket sau diamant.
- **Run selected tournaments** — rulează numărul ales în câmpul numeric. Fiecare turneu nou consumă exact **10 000 Food**.
- **Run until Food stops** — pornește câte un turneu Food și continuă până când jocul sau agentul nu mai poate începe următorul turneu. Se oprește la prima eroare ori ecran nerecunoscut.
- **Stop** — oprește rularea curentă și restabilește `config.json` în `monitor` mode.
- **Check updates** — verifică GitHub la cerere. La pornirea aplicației se face și o verificare informativă în fundal. O actualizare se descarcă și se instalează numai după confirmarea utilizatorului.

## Actualizări

Release-urile stabile sunt publicate în repo-ul GitHub `ToxicOwl/american-dad-mumu-agent`. Updater-ul păstrează pe fiecare PC `config.json`, `.venv`, `captures` și `logs`. Înainte de înlocuirea fișierelor de program, creează un backup local în `backups\update-<dată-oră>` și repornește aplicația actualizată.

Nu instala update-uri în timpul unei rulări Arena. Oprește mai întâi rularea din butonul **Stop**.

## Protecții active

- Folosește numai **Food**, niciodată **Ticket**.
- Nu folosește diamante sau `Quick Attack`.
- Verifică ținta scanată înainte de fiecare `TO BATTLE`.
- Exclude adversarii cu `VICTORY` și buton `TO BATTLE` gri.
- Așteaptă maximum 180 secunde între etape.
- Apasă o singură dată `CLAIM REWARD` sau `NO REWARDS` la final, după recunoașterea strictă a ecranului final.
- Păstrează ultimele 20 de capturi automate; capturile manuale din `captures\` nu sunt șterse.

## Locație

Executabilul trebuie să rămână în `D:\Games\AmericanBot`, lângă folderul `scripts`, deoarece pornește modulele locale PowerShell din acel folder.
