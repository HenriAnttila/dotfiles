---
name: suomi-casual
description: >
  Rento, ihmisen kuuloinen kirjoitustyyli suomeksi (ja englanniksi). Yhdistää suomen
  kielen oikeinkirjoitussäännöt (yhdyssanat, pilkut, taivutus, numerot) ja AI-tekstin
  paljastavien kaavojen karsimisen — oletuksena aina rento sävy. Käytä AINA kun
  kirjoitat, tuotat, käännät tai tarkistat suomenkielistä sisältöä, luot verkkosivujen
  tai markkinoinnin tekstiä, tai kun käyttäjä pyytää tekemään tekstistä vähemmän
  tekoälymäisen, rennomman tai ihmisen kuuloisen. Triggeröi myös oikoluku- ja
  tekstintarkastuspyynnöistä sekä aina kun tuotat sisältöä suomalaiselle sivustolle —
  vaikka suomen kieltä ei erikseen mainittaisi. Also fires in English for
  "make this sound less like AI / more casual / more human."
---

# Rento suomi — writing that sounds like a person, not a model

Two jobs in one skill:
1. **Get the Finnish right** (yhdyssanat, pilkut, taivutus, numerot) — based on Kielitoimiston ohjepankki.
2. **Kill the AI tells** — the structural patterns that make text read as machine-generated, in any language.

Default sävy is **rento (casual)** unless the writer asks for something else. Don't upgrade someone's register: if they write "juttu" and "homma", keep it.

Sources: Kielitoimiston ohjepankki (kielitoimistonohjepankki.fi); Wikipedia "Signs of AI writing" via the avoid-ai-writing ruleset.

---

## Modes

- **Rewrite (default)** — flag the AI-isms, return a rewritten version, then do a second pass on your own rewrite to catch what survived.
- **Detect** — flag only, grouped by severity (P0/P1/P2). Don't rewrite.
- **Edit** — edit the file in place, report only the spans you touched (before → after).

If the writer names a voice other than casual (`asiallinen`, `tekninen`, `lämmin`, `terävä` / professional, technical, warm, blunt), switch targets. Otherwise stay casual.

---

## Part 1 — Casual voice targets (the default)

Concrete targets, not a vibe:

- **Lyhyet virkkeet.** Aim ≤14 words average. Vaihtele pituutta — sekoita lyhyttä ja pitkää. Fragments are fine.
- **Puhuttele lukijaa suoraan:** "sinä", "sä" jos sävy sallii. "Valitset laturin" > "laturi valitaan".
- **Konkretia > lupaukset.** Numero, malli, hinta, esimerkki. "7,4 kW riittää yön yli" > "riittävä latausteho tarpeisiisi".
- **Ota kanta.** Jos jokin on paras, sano se ja perustele. Älä piiloudu neutraaliuteen.
- **Pidä lämpimät täytesanat, karsi korporaatiofraasit.** OK: "rehellisesti", "käytännössä". Pois: "on syytä huomata", "kannattaa mainita".
- **Ansaitse painotus.** Älä kerro että jokin on kiinnostavaa — tee siitä kiinnostavaa.
- **Vähän jargonia.** Jos käytät termin, avaa se kerran.

English casual: contractions throughout (their absence reads stiff), at least one first-person or concrete touch, near-zero jargon.

---

## Part 2 — AI tells to kill (language-agnostic)

Triage by tier. Quick pass = P0 + P1. Full audit = all three.

### P0 — credibility killers (fix now)
- Chatbot-jäänteet: "Toivottavasti tästä on apua!", "Hyvä kysymys!", "Great question!"
- Katkaisuvaroitukset: "Viimeisimmän tietoni mukaan…", "As of my last update…"
- Lähteettömät väitteet: "asiantuntijat uskovat", "tutkimusten mukaan" (ilman lähdettä).
- Merkityksen paisuttelu arkisesta asiasta ("mullistava", "käänteentekevä" latauskaapelista).

### P1 — obvious AI smell (fix before publishing)
- **Kolmen lista pakonomaisesti** — "nopea, luotettava ja edullinen" joka lauseessa. Break the rule of three.
- Kaavamaiset aloitukset: "Nykypäivän nopeatempoisessa maailmassa…", "In the rapidly evolving world of…"
- Geneeriset tulevaisuus-lopetukset: "Tulevaisuus näyttää valoisalta."
- Some-endorsement-lopetukset: "Tämä kannattaa lukea:", "kiitä minua myöhemmin".
- Hedge-pinot: "saattaa mahdollisesti", "voisi periaatteessa" — commit or cut.
- Siirtymäsanojen toisto: "Lisäksi", "Näin ollen", "Moreover", "Furthermore" rivissä.
- **Em-dash koristeena** — English decorative em-dashes for emphasis: use a period. (Ks. Osa 3.7: suomen ajatusviiva numeroväleissä on OK ja oikein.)
- Lihavoinnin ylikäyttö, emojit otsikoissa, "Sukella syvemmälle".
- English wordlist: delve, leverage, robust, harness, tapestry, underscore, pivotal, seamless, crucial → replace with plain words. (Näillä ei ole vaikutusta suomenkieliseen tekstiin — suomen omat tell-sanat: Osa 4.)

### P2 — polish (fix when time allows)
- Tasapaksut kappaleet (kaikki saman mittaisia) — vaihtele.
- Kopulan välttely: "toimii ratkaisuna" → "on ratkaisu"; "boasts / features" → "on / siinä on".
- Synonyymikierto: sama asia kolmella eri sanalla samassa kappaleessa.
- Retoriset kysymysaloitukset: "Mietitkö koskaan, miten…?"
- Täytejohdannot ja -yhteenvedot, jotka toistavat otsikon kertomatta mitään uutta.

**Two quick tests:**
- *Paragraph-reshuffle:* if you can reorder the paragraphs and nothing breaks, the piece has no argument — it's a list pretending to be prose.
- *Treadmill:* lots of words, little new information → cut hard or rewrite from scratch.

---

## Part 3 — Finnish mechanics (get these right)

### 3.1 Yhdyssanat (the #1 error, especially from AI)
Perusmuotoinen substantiivi alussa → AINA yhteen:
- verkkosivusto, verkkokauppa, asiakaspalvelu, tietoturva, latausasema, kotilaturi, sähköauto (EI: verkko sivusto, lataus asema)

Genetiivialku voi olla kumpi vain — merkitys ratkaisee:
- äidinkieli (vakiintunut) vs. äidin kieli (omistus)

Partisiippi/infinitiivi jälkiosana → yleensä ERIKSEEN:
- läsnä oleva, edellä mainittu, voimassa oleva, huomioon ottaen
- Poikkeus (erikoistunut merkitys): silmäänpistävä, asiantunteva

Yhdysmerkki: kirjain/numero/lyhenne alussa → A-rappu, EU-maa, 3-vaiheinen, IP54-luokitus.

### 3.2 Pilkut
- Sivulauseen edelle aina pilkku: että, jos, kun, koska, vaikka, jotta, joka, mikä.
- mutta, vaan, sillä → edelle pilkku.
- ja, tai, sekä → pilkku vain jos molemmat lauseet ovat kokonaisia (oma subjekti + predikaatti).
- **Ei Oxford-pilkkua:** "jauhoja, sokeria ja voita" (EI pilkkua ennen ja-sanaa).
- Desimaalierotin on pilkku: 7,4 kW (EI 7.4).

### 3.3 Iso vai pieni alkukirjain
Pienellä: kielet ja kansallisuudet (suomi, ruotsalainen), viikonpäivät (maanantai), kuukaudet (tammikuu), vuodenajat, tittelit (ministeri, tohtori).
Isolla: erisnimet, virkkeen alku.

### 3.4 Lyhenteet
- Loppulyhenne piste: esim., mm., jne., ns., ks., vrt.
- Isot kirjainlyhenteet pisteettä, taivutus kaksoispisteellä: EU:n, YK:ssa.
- Mittayksiköt pisteettä, taivutus suoraan: kg:n, km:llä.

### 3.5 Numerot ja päivämäärät
- Tuhaterotin = välilyönti (mieluiten sitova, U+00A0): 1 000, 10 000. EI pistettä/pilkkua.
- Yksikön ja luvun väliin välilyönti: 5 kg, 100 km, 15 %, 890 €.
- Päivämäärä: 11.3.2026 (pisteet ilman välilyöntejä) tai 11. maaliskuuta 2026.
- Kellonaika pisteellä: klo 14.30 (EI 14:30).
- Pienet luvut (1–10) mieluummin kirjaimin juoksevassa tekstissä; tarkat/tekniset luvut numeroin.

### 3.6 Lainausmerkit
- Suomessa: ”näin” (ala- ja yläpuoliset). Sisällä: ’näin’.
- EI kulmikkaita »näin» eikä suoria "näin" (digiteksteissä suoria silti käytännössä paljon).

### 3.7 Viivat (tämä ratkaisee dash-ristiriidan)
- Yhdysmerkki `-` (lyhyt): yhdyssanoissa ja tavutuksessa. A-rappu.
- Ajatusviiva `–` (pitkä): numero-/aikaväleissä ja tauoissa: sivut 10–15, klo 8–16, vuosina 2020–2025. **Tämä on oikein — älä poista.**
- **Karsi vain koristeelliset em-dashit** (englannin tyylinen `—` painotuskeinona). Suomen ajatusviiva väleissä säilyy.

---

## Part 4 — Typical AI-Finnish tells (extra watch)
- Anglismit: "ottaa askeleita kohti" → "edetä"; "implementoida" → "toteuttaa"; "adressoida" → "käsitellä".
- Liian juhlava/mahtipontinen sävy (englanninkielisen yritysretoriikan kaiku). Karsi superlatiivit ja kannustavat loppulauseet.
- Yhdyssanavirheet molempiin suuntiin: "verkko sivusto" ja "läsnäoleva".
- Liiallinen passiivi virkatekstissä — aktiivi on selkeämpi ja rennompi.
- Liian jäykkä SVO-sanajärjestys; suomessa painotus liikuttaa sanoja.
- Täytelauseet, kliseet, saman asian toisto eri sanoin.

---

## Part 5 — Tarkistusprosessi
1. **Yhdyssanat** — käy läpi substantiivi+substantiivi ja partisiippi-ilmaukset.
2. **Pilkut** — sivulauseet, päälauseet, ei Oxfordia, desimaalit.
3. **Isot/pienet** — kielet, viikonpäivät, kuukaudet pienellä.
4. **Numerot & lyhenteet** — tuhaterotin välilyönnillä, yksikkövälit, lyhenteiden pisteet.
5. **AI-tells** — Osa 2 (P0→P1→P2) + Osa 4.
6. **Sävy** — onko rento? Lyhyet virkkeet, suora puhuttelu, konkretia, kanta.

If the original is already good, say so and make only the necessary cuts. Don't over-edit.

---

## Output format

**Rewrite (default):** (1) Löydetyt ongelmat (lainaa kohta), (2) Korjattu versio, (3) Mitä muuttui, (4) Toinen tarkistuskierros omaan tekstiisi — korjaa jäljelle jääneet tells.

**Detect:** (1) Ongelmat severityn mukaan (P0/P1/P2), (2) arvio: mitkä on pakko korjata, mitkä harkinnanvaraisia.

**Edit:** muokkaa tiedosto, raportoi vain muutetut kohdat (before → after) + vahvista että luit tiedoston uudelleen.

**Escape hatch:** kun kirjoitat *AI-kaavoista* (kuten tämä tiedosto), lainausmerkeissä/koodilohkoissa olevat esimerkit ovat vapautettuja — älä korjaa niitä.
