# Diktafón 🎙️

Malá appka do hornej lišty Macu: stlačíš skratku, nadiktuješ po slovensky a po druhom stlačení
máš prepísaný text v schránke. Prepis beží **úplne lokálne** na tvojom Macu (model Whisper cez
[whisper.cpp](https://github.com/ggml-org/whisper.cpp)) – funguje offline, zadarmo a hlas nikam neodchádza.

## Inštalácia

Otvor **Terminál** a vlož:

```bash
curl -fsSL https://raw.githubusercontent.com/sivcoalex/copy_transcript/main/install.sh | zsh
```

Skript stiahne appku do Applications, stiahne model (~830 MB, iba raz) a appku spustí.

Ak chceš aj presnejší (asi 2× pomalší) model, ktorý potom zvolíš v menu → Model:

```bash
curl -fsSL https://raw.githubusercontent.com/sivcoalex/copy_transcript/main/install.sh | zsh -s -- --presny
```

**Požiadavky:** Mac s čipom Apple (M1 alebo novší), macOS 14 Sonoma alebo novší, ~1 GB miesta.

## Používanie

1. Pri prvom spustení povoľ prístup k mikrofónu (pýta sa iba raz).
2. Stlač **⌃⌥ medzerník** – ikonka v lište sa zmení na červený krúžok, môžeš diktovať.
3. Stlač skratku znova – o pár sekúnd sa ozve „pop“ a text je v schránke. Vlož ho cez **⌘V**.

V menu ikonky nájdeš:
- **Nastaviť skratku…** – vlastná klávesová skratka
- **Upraviť slovník…** – slová a názvy, ktoré má model písať presne (napr. `Claude Code`), a opravy typu `Cloud Code => Claude Code`
- **Mikrofón** – automaticky alebo napevno zvolený mikrofón
- **Model** – rýchly / presnejší
- posledných 5 prepisov, zvuky, spúšťanie po prihlásení

Model sa načíta do pamäte až pri diktovaní a 3 minúty po poslednom použití sa uvoľní,
takže v nečinnosti appka zaberá len pár desiatok MB.

## Odinštalovanie

```bash
pkill -x Diktafon; rm -rf /Applications/Diktafon.app ~/Library/Application\ Support/Diktafon
```

Položku v Nastaveniach systému → Všeobecné → Prihlasovacie položky odstrániš ručne, ak tam zostane.

## Zostavenie zo zdrojového kódu

Treba Xcode Command Line Tools a `cmake` (`brew install cmake`).

```bash
./build.sh            # zostaví build/Diktafon.app
./build.sh --install  # zostaví a nainštaluje do /Applications
```

Appka je podpísaná iba lokálne (nie certifikátom Apple). Pri inštalácii cez `curl` to nevadí;
ak by si zip stiahol cez prehliadač a macOS appku zablokoval, otvor ju pravým klikom → Otvoriť.

Licencie použitých knižníc sú v [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
