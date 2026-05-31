# Recupero MCU testa "bricckato" su Sovol SV08 Max — senza hardware esterno

Recupero di un MCU della **testa di stampa** (o della scheda buffer filamento) di una
**Sovol SV08 Max** quando il suo firmware è corrotto e non comunica più via CAN,
**usando l'SBC della stampante stessa come programmatore SWD** (niente ST-Link, niente Arduino).

**Autore:** Matteo Di Cristoforo
**Licenza:** MIT (vedi `LICENSE`)

> ⚠️ Guida tecnica avanzata. Lavorare sul firmware degli MCU comporta il rischio di
> danneggiare la scheda. Procedi a tuo rischio e solo se sai cosa stai facendo.

---

## 1. Il contesto hardware

La SV08 Max ha tre microcontrollori + un piccolo computer Linux:

| Componente | Cosa | Note |
|-----------|------|------|
| **STM32H750** | MCU principale (motion) sulla scheda madre | fa anche da bridge USB↔CAN |
| **H616 (BTT CB1)** | SBC Linux (Klipper/Moonraker) | sulla scheda madre, header seriale "5V RX TX GND" accessibile |
| **STM32F103C8** | MCU della **testa** (hotend, estrusore, sonda eddy) | UUID CAN `61755fe321ac`, collegato via umbilical |
| **STM32F103C8** | MCU della **scheda buffer filamento** | UUID CAN `704fe1305bd6` |

I due STM32F103 hanno **Katapult** (bootloader CAN) + Klipper, e un header **SWD** a 4 pad
etichettato `3V3 IO CK G` (IO=SWDIO/PA13, CK=SWCLK/PA14).

## 2. Il problema (come ci si "bricca")

Compilando il firmware Klipper per questi MCU con l'**offset di flash sbagliato**
(applicazione a `0x8000000` invece di `0x8002000`, dove Katapult occupa i primi 8 KiB),
il flash via Katapult "riesce" ma i vettori di reset puntano nella regione di Katapult →
all'avvio l'MCU salta a codice non valido e **si blocca**.

Perché **non** si recupera via CAN:
- Katapult gira solo ~1 secondo all'accensione, poi salta all'app (che "sembra valida") → niente finestra catturabile
- Niente pulsante BOOT/reset accessibile; il double-reset via power cycle non funziona (la RAM si azzera)
- L'MCU bloccato non dà ACK sul bus CAN → l'intero TX del bus va in stallo

**Conclusione:** serve lo **SWD**, che accede direttamente al chip ignorando l'app rotta.

## 3. L'idea: l'SBC come programmatore SWD (a costo zero)

L'header seriale di debug **"5V RX TX GND"** della scheda madre è la **console UART0** dell'H616
sui GPIO **PH0 (TX, linea 224)** e **PH1 (RX, linea 225)**. Liberando quei pin dalla UART,
**OpenOCD** può fare **SWD bit-bang** tramite il driver `linuxgpiod`, usando l'SBC stesso
come sonda. Bastano 3 fili fino ai pad SWD della testa.

### Cablaggio (3 fili)
| Scheda madre "5V RX TX GND" | → | Testa "3V3 IO CK G" |
|:--:|:--:|:--:|
| **TX** (PH0/224 = SWCLK) | → | **CK** |
| **RX** (PH1/225 = SWDIO) | → | **IO** |
| **GND** | → | **G** |

- **3V3/5V non si collegano**: la testa è alimentata dai suoi 24V (stampante accesa). Massa comune (anche via umbilical).
- Logica 3.3 V su entrambi i lati → compatibile.

## 4. I tre dettagli che fanno la differenza

1. **Sistema scarico**: il bit-bang dipende dal timing software. Con Klipper/Moonraker attivi
   lo scheduling sfasa i bit e OpenOCD non aggancia. **Fermare tutti i servizi** prima.
2. **Priorità realtime**: lanciare OpenOCD con `chrt -f 99` per ridurre il jitter.
3. **L'offset è la regola d'oro**: o **Katapult a `0x8000000` + Klipper a `0x8002000`**,
   oppure un **Klipper standalone compilato per `0x8000000`** scritto a `0x8000000`.
   **Mai incrociare le due cose.** Prima di scrivere, lo script fa `stm32f1x unlock 0`
   (gestisce l'eventuale protezione di lettura RDP con mass-erase).

## 5. Come si usa lo script

Sull'SBC (via SSH):
```bash
# 1) compila Katapult e Klipper per l'F103 con offset 0x2000 (vedi commenti nello script)
# 2) metti i 3 file/percorsi nello script e lancia:
sudo bash recupero_testa_swd.sh
```
Lo script: ferma i servizi → libera la UART → testa lo SWD (con ritentativi) → flasha
Katapult+Klipper → ripristina la console UART. Dopo, riallinea il firmware host
(es. `ldc1612.py`) alla versione del firmware MCU flashato e riavvia Klipper.

## 6. Note finali

- Lato host: il firmware Klipper dell'MCU e i moduli Python dell'host devono **combaciare**
  (es. il comando `ldc1612_setup_home` con/senza `homing_method` tra branch `main` ed
  `eddy_contact`). Disallineamento → "Command format mismatch".
- Una volta reinstallato **Katapult**, i flash futuri si fanno comodamente via CAN
  (`flash_can.py`), senza più SWD.
- Stessa identica procedura per la **scheda buffer filamento** (UUID `704fe1305bd6`),
  sui pad SWD della sua scheda.

*Documentato dopo un recupero reale, 31/05/2026.*
