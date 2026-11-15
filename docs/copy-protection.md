# Copy-protection answers

Questions the supported stories ask whose answers come from the
original package (manual, feelies).  The Cutthroats and Bureaucracy
answers were also checked against the tables inside the story files,
which accept the alternatives listed.

How each was tested:

- **Stationfall, Starcross, Border Zone, Cutthroats (Leviathan):** played up
  to the prompt and answered; the game accepts the answer and moves on.
- **Bureaucracy:** the paranoid's quiz routine was called directly in a
  throwaway build of the interpreter and answered under 25 seeds. All 15
  questions came up, every answer was accepted, and every run ended "You
  passed the test."
- **Cutthroats (São Vera), Spellbreaker:** checked against the coordinate
  check and the answer table in the story files, but not played.

| # | Game | Package item | Question (as the game asks it) | Answer |
|---|---|---|---|---|
| 1 | Stationfall | Assignment Completion Form | "Spacecraft activated. Type in the course heading." The course depends on the Galactic Standard Time on your chronometer (4929 in a `--seed 1` run). Please give the whole time → course chart. | See the chart below (4929 → **392**, verified: the truck docks) |
| 2 | Starcross | Space chart | The mass detector shows a random target ("mass UM24" with `--seed 1`; UM12, UM28, UM31 and UM70 with other seeds). The computer needs R, theta and phi from the chart. Please give R / theta / phi for every UM on the chart. | See the chart below (UM24 → range 100, theta 285, phi 087, verified: the ship reaches the artifact) |
| 3 | Cutthroats | *Four Shipwrecks off Hardscrabble Island* map ([`cutthroa.pdf`](https://infodoc.plover.net/manuals/temp/cutthroa.pdf)) | Johnny: "We'll need you to supply the minutes of longitude and latitude of the wreck." Johnny shows a gold coin for the Sao Vera or a dinner plate for the Leviathan. Sao Vera latitude / longitude: | Latitude 40, longitude 45 (where the wreck drifted to). Matches the game's coordinate check (site 1, 400 ft); not played |
| 4 | Cutthroats | (same) | Leviathan latitude / longitude: | Latitude 25, longitude 25 (where the wreck drifted to). **Played**: `johnny, the latitude is 25` / `johnny, the longitude is 25`; the dive lands on the Leviathan's top deck, while the walkthrough's 30/15 lands on empty ocean floor |
| 5 | Border Zone | *Frobnia* tourist guide and phrasebook ([`borderzo.pdf`](https://infodoc.plover.net/manuals/temp/borderzo.pdf)) | Chapter 1, train platform: the contact greets you with "Forgive me." and you must reply "It is my fault." in Frobnian. Frobnian for "Forgive me": | Hartzí dazí |
| 6 | Border Zone | (same) | Frobnian for "It is my fault": | `say "popka izim"` (Popka ízím). **Played**: a boy greets you with "Hartzi dazi!", the reply is accepted and chapter 1 ends in success |
| 7 | Spellbreaker | Spell cards | Belboz asks one at random: "Which of our esteemed colleagues was fabled for his skill at Double Fanucci?" | Forburn (the Wily). Matches the game's answer table (`forbur`); not played |
| 8 | Spellbreaker | (same) | "In Borphee, who was famed for his skill with fireworks displays?" | Dimithio (of Borphee). Matches the answer table (`dimith`); not played |
| 9 | Spellbreaker | (same) | "Of the necromancers, who other than (harumph) myself is best-known?" | Berknip. Matches the answer table (`berkni`); not played |
| 10 | Spellbreaker | (same) | "Who wrote the Coconut of Quendor?" | Gustar (Woomax). Matches the answer table (`gustar`); not played |
| 11 | Spellbreaker | (same) | "Who invented the golmac spell?" | Barbel (of Gurth). Matches the answer table (`barbel`); not played |
| 12 | Spellbreaker | (same) | "Which mage had the motto, 'The hardest trick is making it look easy'?" | Barsap. Matches the answer table (`barsap`); not played |
| 13 | Bureaucracy | *Popular Paranoia* flyer ([`bureaucr.pdf`](https://infodoc.plover.net/manuals/bureaucr.pdf)) | The paranoid asks a few at random: "What chemical is the international health conspiracy using to destroy our valuable body fat?" | aspartame (also: nutrasweet) |
| 14 | Bureaucracy | (same) | "What do Ronald Wilson Reagan, Daniel Miguel Ortega, Dwight Eugene Gooden and Johnny Herman Carson have in common (and are a menace because of it)?" | 666 |
| 15 | Bureaucracy | (same) | "What device is used by the banks to keep track of the whereabouts of American citizens?" | automatic teller machines (also: atm) |
| 16 | Bureaucracy | (same) | "Where is the centre of communist insurgency in the United States?" | Ohio |
| 17 | Bureaucracy | (same) | "The existence of which one of the fifty states of the union is a fiction invented by the Trilateral Commission for its own nefarious purposes?" | Delaware |
| 18 | Bureaucracy | (same) | "What left-wing organisation foiled the coup d'etat directly after the assassination of John F. Kennedy, leading to decades of crypto-communist government in America?" | NFL (also: national football league) |
| 19 | Bureaucracy | (same) | "What is the breeding ground for most major diseases?" | yogurt |
| 20 | Bureaucracy | (same) | "How do THEY learn so much about you?" | garbage |
| 21 | Bureaucracy | (same) | "By what percentage do students who exchange digital watches with multiple partners increase their chances of contracting bubonic plague?" | 300 |
| 22 | Bureaucracy | (same) | "What local government-subsidised program poses the greatest threat to home privacy?" | cable tv (also: cable television) |
| 23 | Bureaucracy | (same) | "What are the Mexicans unleashing on the United States for refusing to grant Mexico a major-league baseball franchise?" | killer bees |
| 24 | Bureaucracy | (same) | "What secret FBI surveillance method is masquerading under the guise of a public service?" | traffic helicopters (also: traffic copters) |
| 25 | Bureaucracy | (same) | "Who is THEIR leader?" | Queen Mum |
| 26 | Bureaucracy | (same) | "What well-meaning legislation was actually a communist-inspired plot to destroy the American family?" | GI Bill |
| 27 | Bureaucracy | (same) | "How are the dentists of America conspiring to destroy the minds of our children?" | novocaine |

## Starcross: mass detector output

From the M.C.S. Starcross chart ([`starcros.pdf`](https://infodoc.plover.net/manuals/temp/starcros.pdf)). Type
`computer, range is R. theta is T. phi is P`, then `computer, confirm new
course`, then sit in the couch and fasten the seat belt before the burn.

| Name | Range | Theta | Phi |
|---|---|---|---|
| UM08 | 150 | 110 | 017 |
| UM12 | 100 | 345 | 107 |
| UM24 | 100 | 285 | 087 |
| UM28 | 250 | 45 | 178 |
| UM31 | 150 | 105 | 067 |
| UM52 | 175 | 165 | 035 |
| UM70 | 100 | 135 | 101 |
| UM91 | 50 | 15 | 121 |
| AX01 (asteroid) | 200 | 240 | 134 |
| AX32 (asteroid) | 125 | 240 | 105 |
| AX71 (asteroid) | 125 | 180 | 047 |
| AX87 (asteroid) | 125 | 75 | 102 |
| AB40 (inhabited asteroid) | 250 | 300 | 022 |
| US75 (ship) | 175 | 135 | 034 |

The Spellbreaker answers come from the spell cards ([`spellbre.pdf`](https://infodoc.plover.net/manuals/temp/spellbre.pdf)).

## Stationfall: astrogator's navigational data

From Assignment Completion Form QX-17-T ([`stationf.pdf`](https://infodoc.plover.net/manuals/stationf.pdf)). Find the
chronometer time's range and `type` the course.

| Time | Course | Time | Course | Time | Course | Time | Course |
|---|---|---|---|---|---|---|---|
| 4300-4349 | 632 | 5700-5749 | 184 | 7100-7149 | 128 | 8500-8549 | 464 |
| 4350-4399 | 609 | 5750-5799 | 175 | 7150-7199 | 133 | 8550-8599 | 483 |
| 4400-4449 | 587 | 5800-5849 | 167 | 7200-7249 | 139 | 8600-8649 | 503 |
| 4450-4499 | 565 | 5850-5899 | 159 | 7250-7299 | 145 | 8650-8699 | 523 |
| 4500-4549 | 544 | 5900-5949 | 152 | 7300-7349 | 152 | 8700-8749 | 544 |
| 4550-4599 | 523 | 5950-5999 | 145 | 7350-7399 | 159 | 8750-8799 | 565 |
| 4600-4649 | 503 | 6000-6049 | 139 | 7400-7449 | 167 | 8800-8849 | 587 |
| 4650-4699 | 483 | 6050-6099 | 133 | 7450-7499 | 175 | 8850-8899 | 609 |
| 4700-4749 | 464 | 6100-6149 | 128 | 7500-7549 | 184 | 8900-8949 | 632 |
| 4750-4799 | 445 | 6150-6199 | 123 | 7550-7599 | 193 | 8950-8999 | 655 |
| 4800-4849 | 427 | 6200-6249 | 119 | 7600-7649 | 203 | 9000-9049 | 679 |
| 4850-4899 | 409 | 6250-6299 | 115 | 7650-7699 | 213 | 9050-9099 | 703 |
| 4900-4949 | 392 | 6300-6349 | 112 | 7700-7749 | 224 | 9100-9149 | 728 |
| 4950-4999 | 375 | 6350-6399 | 109 | 7750-7799 | 235 | 9150-9199 | 753 |
| 5000-5049 | 359 | 6400-6449 | 107 | 7800-7849 | 247 | 9200-9249 | 779 |
| 5050-5099 | 343 | 6450-6499 | 105 | 7850-7899 | 259 | 9250-9299 | 805 |
| 5100-5149 | 328 | 6500-6549 | 104 | 7900-7949 | 272 | 9300-9349 | 832 |
| 5150-5199 | 313 | 6550-6599 | 103 | 7950-7999 | 285 | 9350-9399 | 859 |
| 5200-5249 | 299 | 6600-6649 | 103 | 8000-8049 | 299 | 9400-9449 | 887 |
| 5250-5299 | 285 | 6650-6699 | 103 | 8050-8099 | 313 | 9450-9499 | 915 |
| 5300-5349 | 272 | 6700-6749 | 104 | 8100-8149 | 328 | 9500-9549 | 944 |
| 5350-5399 | 259 | 6750-6799 | 105 | 8150-8199 | 343 | 9550-9599 | 973 |
| 5400-5449 | 247 | 6800-6849 | 107 | 8200-8249 | 359 | | |
| 5450-5499 | 235 | 6850-6899 | 109 | 8250-8299 | 375 | | |
| 5500-5549 | 224 | 6900-6949 | 112 | 8300-8349 | 392 | | |
| 5550-5599 | 213 | 6950-6999 | 115 | 8350-8399 | 409 | | |
| 5600-5649 | 203 | 7000-7049 | 119 | 8400-8449 | 427 | | |
| 5650-5699 | 193 | 7050-7099 | 123 | 8450-8499 | 445 | | |

Not included: package items that carry information but never gate progress
with a typed answer (Sorcerer's infotater, The Witness's telegram and
matchbook, Infidel's map, Hollywood Hijinx's photo, the Deadline and Suspect
dossiers). The V6 games (Arthur, Journey, Shogun, Zork Zero) don't run here.
