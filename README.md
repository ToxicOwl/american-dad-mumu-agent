# American Dad! MuMu Agent — nucleu actualizabil

Acesta este un proiect nou, local și editabil pentru MuMu Player. Nu reutilizează executabilul închis din pachetul din 2021. Comunicarea se face direct prin ADB cu profilul deja validat pentru MuMu:

- **ADB:** `C:\Program Files\MuMuPlayer\nx_main\adb.exe`
- **Instanță:** `127.0.0.1:7555`
- **Captură joc:** `1280 × 720`, landscape

## Important: versiunea 0.2.0 este intenționat sigură

Versiunea 0.2.0 include monitorizarea fără input și trei acțiuni cu un singur tap, strict protejate. Acestea sunt disponibile numai după ce ecranul corect este recunoscut și utilizatorul confirmă explicit comanda. Nu există acțiuni automate în buclă.

- verifică conexiunea ADB, versiunea Android și dimensiunea capturii;
- salvează capturi din MuMu direct pe PC;
- generează șabloane de recunoaștere din ecranul actual;
- detectează ecranul principal după un șablon ales de utilizator;
- salvează un jurnal JSON local în `logs/agent.jsonl`;
- rulează în mod de monitorizare, fără interacțiune cu Android.
- simulează sau execută un singur tap pentru cufărul zilnic, cadourile primite și cadourile de la prieteni.

Păstrează `safety.mode: monitor` până când verifici mai întâi fiecare acțiune în mod `--dry-run`.

## Instalare în Windows

### 1. Descarcă și dezarhivează pachetul

Extrage arhiva, de exemplu în:

```text
C:\Tools\ad-mumu-agent
```

### 2. Instalează Python, doar dacă nu îl ai deja

Este necesar **Python 3.10 sau mai nou**. La instalare, bifează opțiunea **Add Python to PATH**. Nu este nevoie de Android Studio, root sau ADB instalat separat: agentul folosește ADB-ul din MuMu.

### 3. Rulează instalarea o singură dată

Deschide PowerShell în folderul proiectului și rulează:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\scripts\setup-windows.ps1
```

Comanda creează un mediu Python local în `.venv`, instalează biblioteca de imagine și creează `config.json` din profilul pregătit pentru MuMu. Versiunea 0.2.0 folosește numai biblioteci cu pachete precompilate pentru Python 3.15; nu sunt necesare Microsoft C++ Build Tools.

### 4. Verifică MuMu

Pornește MuMu și jocul. În același PowerShell rulează:

```powershell
.\scripts\run-agent.ps1 doctor
```

Rezultatul dorit include:

```text
Target device: 127.0.0.1:7555
Device state: device
Android: 15
Screenshot size: 1280x720; expected 1280x720 [OK]
```

Fișierul de control `captures/doctor-latest.png` trebuie să conțină ecranul jocului. Dacă ecranul este corect, conexiunea este pregătită.

## Calibrarea ecranului principal

Cu jocul lăsat pe baza principală, selectează în captură o zonă care rămâne neschimbată și este specifică acestui ecran. Evită numele jucătorului, resursele, contoarele, chat-ul, reclamele, animațiile și zonele care se mișcă.

Pentru a crea un șablon, rulează:

```powershell
.\scripts\run-agent.ps1 calibrate-template main_base X Y WIDTH HEIGHT
```

Înlocuiește `X`, `Y`, `WIDTH`, `HEIGHT` cu coordonatele din captura de 1280 × 720. De exemplu:

```powershell
.\scripts\run-agent.ps1 calibrate-template main_base 585 165 150 70
```

Comanda salvează decupajul în `calibration/templates/main_base.png` și îl adaugă în `config.json`. Pentru a utiliza acel șablon, `monitor.main_screen_template` trebuie să fie `main_base`.

Dacă nu știi ce zonă să selectezi, rulează:

```powershell
.\scripts\run-agent.ps1 capture base
```

și trimite captura generată pentru alegerea coordonatelor. Poți ascunde ID-uri, nume și conversații înainte să o trimiți.

## Monitorizare sigură

După calibrare, verifică o singură observație:

```powershell
.\scripts\run-agent.ps1 once
```

Apoi monitorizează cinci cicluri, o dată la cinci secunde:

```powershell
.\scripts\run-agent.ps1 monitor --count 5
```

Un rezultat bun va spune `main_base` și va avea un scor al șablonului de cel puțin `0.880`. Dacă apare `unrecognized`, deschide captura din `captures/`, schimbă decupajul și testează din nou.

Oprirea monitorului se face imediat cu **Ctrl+C**. Monitorul nu poate produce clicuri, nici din greșeală.

## Acțiuni protejate, câte un singur tap

Acțiunile disponibile sunt:

- `daily-chest-open` — apasă numai butonul verde **OPEN** de la Daily Chest;
- `gifts-claim-all` — apasă numai **CLAIM ALL** din fereastra de cadouri primite;
- `gifts-claim-all-despite-no-space` — apasă **CLAIM ALL**, apoi apasă **CLAIM** numai dacă apare și este recunoscut exact dialogul **No space**;
- `gifts-confirm-no-space` — apasă **CLAIM** numai în dialogul **No space** deja afișat și recunoscut;
- `friends-claim-gifts` — apasă numai **CLAIM GIFTS** din tabul Friends.

Fiecare acțiune verifică toate condițiile înainte de input: ADB, instanța configurată, dimensiunea de 1280 × 720, recunoașterea strictă a ecranului potrivit și `safety.forbid_diamond_spend: true`. Dacă o verificare eșuează, nu trimite tap-ul. Pentru acțiunea cu spațiu insuficient, al doilea tap este blocat dacă dialogul **No space** nu are un scor de recunoaștere de cel puțin `0.960`. Nu are cod care să apese reclame, achiziții cu diamante, chat, lupte, pop-up-uri nevalidate sau butonul de închidere.

Mai întâi listează acțiunile:

```powershell
.\scripts\run-agent.ps1 actions
```

Deschide manual ecranul dorit în joc și rulează simularea. Aceasta nu trimite niciun tap:

```powershell
.\scripts\run-agent.ps1 action gifts-claim-all --dry-run
```

Numai dacă rezultatul spune `DRY RUN PASSED`, editează `config.json`, schimbă exclusiv acest câmp:

```json
"mode": "actions"
```

Apoi, pe același ecran recunoscut, autorizează exact un tap:

```powershell
.\scripts\run-agent.ps1 action gifts-claim-all --confirm
```

Agentul salvează obligatoriu capturi înainte și după fiecare tap în `captures/`. După acțiune, revino la `"mode": "monitor"` în `config.json`.

## Structura proiectului

```text
ad_agent/                    Codul sursă Python
config.json                  Profilul local activ (creat la instalare)
config.example.json          Model de profil pentru MuMu
calibration/templates/       Decupaje pentru recunoașterea ecranelor
captures/                    Capturi de diagnostic locale
logs/agent.jsonl             Jurnal local, câte un obiect JSON pe linie
scripts/setup-windows.ps1    Instalare locală
scripts/run-agent.ps1        Lansator simplu
```

## Actualizarea după un update al jocului

Dacă jocul își schimbă grafica, nu este necesară recompilarea agentului. Rulează din nou `capture`, actualizează numai șabloanele din `calibration/templates/` și verifică monitorizarea. Codul și `config.json` rămân editabile.

## Limite și utilizare responsabilă

Automatizarea unui joc online poate încălca termenii jocului și poate avea consecințe asupra contului. Folosește acest proiect doar pe propriul risc. Nu include și nu solicita credențiale de Google, parole de joc sau date de plată.

## Dezvoltare

Pe un sistem cu Python, instalează proiectul și `pytest`, apoi rulează testele:

```bash
python -m pip install -e . pytest
python -m pytest
```
